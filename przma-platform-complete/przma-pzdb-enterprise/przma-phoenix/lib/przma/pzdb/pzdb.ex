# lib/przma/pzdb/pzdb.ex
#
# PRZMA.PzDb — single public API for all Lance DB operations.
#
# All service code calls PRZMA.PzDb.write/3 or PRZMA.PzDb.read/2.
# This module wires together: WriteRouter → VaultWriter → NIF → Lance.
#
# Write pipeline (guaranteed for every call):
#   1. Health check       — circuit breaker, reject if storage unavailable
#   2. Encrypt            — encryption context, before any NIF call
#   3. Route              — consistent hash to correct cluster node
#   4. Serialise          — VaultWriter GenServer, sequential per DID
#   5. Upsert             — pzdb_upsert NIF (merge_insert, OCC retry)
#   6. Version tag        — returned in WriteResult
#   7. Cache invalidate   — ReadCache.invalidate for the written URI
#   8. Index              — MetadataIndex async emit (non-blocking)
#   9. Telemetry          — HealthMonitor.record_success / record_error
#
# Read pipeline:
#   1. Cache check        — ReadCache.get — O(1) ETS lookup
#   2. NIF read           — pzdb_read with optional min_version
#   3. Decrypt            — encryption context
#   4. Cache warm         — ReadCache.put if record is hot
#   5. Return             — with version tag
#
# Fan-out (for circle replication and batch ops):
#   - pzdb_fan_out/3 uses Task.async_stream over member list
#   - Each member write is routed independently (own node, own VaultWriter)
#   - Failures are collected, not immediately raised

defmodule PRZMA.PzDb do
  alias PRZMA.PzDb.{VaultWriter, WriteRouter, ReadCache, HealthMonitor}
  alias PRZMA.Calendar.Storage.EncryptionContext
  alias PRZMA.Calendar.NIF
  alias PRZMA.Platform.MetadataIndex

  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── WRITE ───────────────────────────────────────────────────────────────────

  @doc """
  Write a record under a pzdb:// URI. Returns {:ok, write_result} | {:error, reason}.

  write_result contains:
    record_id:  the id field of the written record
    version:    Lance manifest version after commit (use for min_version on reads)
    attempts:   number of OCC retries needed
    latency_us: total write time in microseconds

  Options:
    :index_opts — map of title:/snippet:/tags: for MetadataIndex (omit to skip)
    :encrypt    — boolean, default true (false only for tests/migration)
    :key_columns — list of columns to match on for upsert, default ["id"]
  """
  def write(pzdb_uri, record, opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    with :ok <- HealthMonitor.check() do
      start = System.monotonic_time(:microsecond)

      did        = extract_did(pzdb_uri)
      table_path = resolve_table_path(pzdb_uri)
      key_cols   = opts[:key_columns] || ["id"]
      encrypt    = Keyword.get(opts, :encrypt, true)

      record_json =
        if encrypt and EncryptionContext.encryption_available?(did) do
          encrypt_record(did, record)
        else
          Jason.encode!(record)
        end

      # Route → serialise → upsert
      result = WriteRouter.write(did, fn ->
        NIF.pzdb_upsert(
          @base_path,
          table_path,
          record_json,
          Jason.encode!(key_cols)
        )
      end)

      latency_us = System.monotonic_time(:microsecond) - start

      case result do
        {:ok, result_json} ->
          write_result = Jason.decode!(result_json)

          # Invalidate read cache
          ReadCache.invalidate(pzdb_uri)

          # Emit to metadata index (async, non-blocking)
          if index_opts = opts[:index_opts] do
            Task.start(fn ->
              MetadataIndex.index(did, pzdb_uri, Map.to_list(index_opts))
            end)
          end

          HealthMonitor.record_success(latency_us)
          :telemetry.execute([:pzdb, :write, :ok],
            %{latency_us: latency_us, attempts: write_result["attempts"]},
            %{uri: pzdb_uri})

          {:ok, write_result}

        {:error, :backpressure} ->
          {:error, :backpressure}

        {:error, :circuit_open} ->
          {:error, :storage_unavailable}

        {:error, msg} ->
          HealthMonitor.record_error(msg)
          :telemetry.execute([:pzdb, :write, :error], %{count: 1}, %{uri: pzdb_uri})
          {:error, msg}
      end
    end
  end

  @doc """
  Write multiple records to the same table in one atomic operation.
  All succeed or all fail.
  """
  def batch_write(pzdb_table_uri, records, opts \\ [])
      when is_binary(pzdb_table_uri) and is_list(records) do
    with :ok <- HealthMonitor.check() do
      did        = extract_did(pzdb_table_uri)
      table_path = resolve_table_path(pzdb_table_uri)
      key_cols   = opts[:key_columns] || ["id"]

      records_json = Jason.encode!(records)

      WriteRouter.write(did, fn ->
        NIF.pzdb_batch_upsert(
          @base_path,
          table_path,
          records_json,
          Jason.encode!(key_cols)
        )
      end)
      |> case do
        {:ok, json}   -> {:ok, Jason.decode!(json)}
        {:error, msg} ->
          HealthMonitor.record_error(msg)
          {:error, msg}
      end
    end
  end

  @doc """
  Soft-delete a record — sets deleted_at, does not remove from Lance.
  Physical removal happens during compaction.
  """
  def delete(pzdb_uri, deleted_by) when is_binary(pzdb_uri) do
    with :ok <- HealthMonitor.check() do
      did        = extract_did(pzdb_uri)
      table_path = resolve_table_path(pzdb_uri)
      record_id  = extract_record_id(pzdb_uri)

      result = WriteRouter.write(did, fn ->
        NIF.pzdb_soft_delete(@base_path, table_path, record_id, deleted_by)
      end)

      case result do
        {:ok, json}   ->
          ReadCache.invalidate(pzdb_uri)
          MetadataIndex.deindex(did, pzdb_uri)
          {:ok, Jason.decode!(json)}
        {:error, msg} -> {:error, msg}
      end
    end
  end

  # ── READ ────────────────────────────────────────────────────────────────────

  @doc """
  Read a single record by pzdb:// URI.
  Returns {:ok, %{record: map, version: n, found: bool}} | {:error, reason}

  Options:
    :min_version — wait for this Lance version before reading (read-after-write)
    :skip_cache  — bypass ETS read cache (default: false)
    :decrypt     — boolean, default true
  """
  def read(pzdb_uri, opts \\ []) when is_binary(pzdb_uri) do
    skip_cache  = opts[:skip_cache]  || false
    min_version = opts[:min_version] || 0
    decrypt     = Keyword.get(opts, :decrypt, true)
    did         = extract_did(pzdb_uri)

    # Cache check (skip if min_version specified — need freshness guarantee)
    if not skip_cache and min_version == 0 do
      case ReadCache.get(pzdb_uri) do
        {:hit, record, version} ->
          :telemetry.execute([:pzdb, :read, :cache_hit], %{count: 1}, %{uri: pzdb_uri})
          {:ok, %{record: record, version: version, found: true, cached: true}}
        :miss ->
          do_read(pzdb_uri, did, min_version, decrypt)
      end
    else
      do_read(pzdb_uri, did, min_version, decrypt)
    end
  end

  @doc """
  Read multiple records matching a filter.
  Bypasses the single-record read cache.

  Options:
    :filter      — SQL WHERE clause string
    :limit       — max records (default 100)
    :min_version — read-after-write version guarantee
  """
  def query(pzdb_table_uri, opts \\ []) when is_binary(pzdb_table_uri) do
    table_path  = resolve_table_path(pzdb_table_uri)
    filter      = opts[:filter]      || ""
    limit       = opts[:limit]       || 100
    min_version = opts[:min_version] || 0

    case NIF.pzdb_read_many(@base_path, table_path, filter, limit, min_version) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Get the current manifest version for a pzdb table URI"
  def version(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    table_path = resolve_table_path(pzdb_table_uri)
    case NIF.pzdb_version(@base_path, table_path) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── FAN-OUT WRITE ───────────────────────────────────────────────────────────

  @doc """
  Write the same logical record to multiple DIDs' vaults in parallel.
  Used for circle event replication, notification fan-out, etc.

  Each write is independent:
    - Routes to the correct cluster node per DID
    - Retries on OCC conflict independently
    - Failures are collected and reported, not raised

  Returns {:ok, %{succeeded: [uri], failed: [{uri, reason}]}}
  """
  def fan_out(uri_record_pairs, opts \\ []) when is_list(uri_record_pairs) do
    concurrency = opts[:concurrency] || 10
    timeout_ms  = opts[:timeout_ms]  || 15_000

    results = Task.async_stream(
      uri_record_pairs,
      fn {pzdb_uri, record} ->
        {pzdb_uri, write(pzdb_uri, record, opts)}
      end,
      max_concurrency: concurrency,
      timeout:         timeout_ms,
      on_timeout:      :kill_task
    )
    |> Enum.reduce({[], []}, fn
      {:ok, {uri, {:ok, result}}},  {ok, err} -> {[{uri, result} | ok], err}
      {:ok, {uri, {:error, msg}}},  {ok, err} -> {ok, [{uri, msg} | err]}
      {:exit, {uri, :timeout}},     {ok, err} -> {ok, [{uri, :timeout} | err]}
      _,                            {ok, err} -> {ok, err}
    end)

    {succeeded, failed} = results
    %{succeeded: Enum.reverse(succeeded), failed: failed}
  end

  # ── TABLE MANAGEMENT ────────────────────────────────────────────────────────

  @doc """
  Ensure a Lance table exists for the given URI.
  Idempotent — safe to call on every service startup or first write.
  """
  def ensure_table(pzdb_table_uri, schema_name) when is_binary(pzdb_table_uri) do
    table_path = resolve_table_path(pzdb_table_uri)
    case NIF.pzdb_provision_table(@base_path, table_path, schema_name) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Provision all standard tables for a DID across all services.
  Call once on user account creation.
  """
  def provision_vault(did) do
    tables = [
      {"vault/core/entries",              "entries"},
      {"vault/core/practice_logs",        "practice_logs"},
      {"calendar/core/events",            "events"},
      {"calendar/core/tasks",             "tasks"},
      {"calendar/core/availability",      "availability"},
      {"calendar/core/booking_links",     "booking_links"},
      {"calendar/core/reminders",         "reminders"},
      {"calendar/core/polls",             "polls"},
      {"calendar/core/transcripts",       "transcripts"},
      {"chat/core/messages",              "messages"},
      {"chat/core/threads",               "threads"},
      {"files/core/files",                "files"},
      {"metadata/core/search_index",      "search_index"},
      {"metadata/core/references",        "references"},
      {"metadata/core/tags",              "tags"},
      {"ai/core/model_registry",          "model_registry"},
      {"ai/core/inference_log",           "inference_log"},
      {"agents/core/sessions",            "sessions"},
      {"creative/core/projects",          "projects"},
      {"companion/core/memories",         "memories"},
      {"companion/core/sapience_snapshots","sapience_snapshots"},
      {"companion/core/arc_timeline",     "arc_timeline"},
      {"social/core/memberships",         "memberships"},
      {"social/core/followers",           "followers"},
    ]

    results = Enum.map(tables, fn {path, schema} ->
      full_path = "pzdb://#{did}/#{path}/placeholder"
      {path, ensure_table(full_path, schema)}
    end)

    failed = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)
    if Enum.empty?(failed) do
      {:ok, %{tables_provisioned: length(tables)}}
    else
      {:error, %{failed: failed}}
    end
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────────────

  defp do_read(pzdb_uri, did, min_version, decrypt) do
    table_path = resolve_table_path(pzdb_uri)
    record_id  = extract_record_id(pzdb_uri)

    case NIF.pzdb_read(@base_path, table_path, record_id, min_version) do
      {:ok, json} ->
        result = Jason.decode!(json)
        record = result["record"]

        # Decrypt if needed
        record = if decrypt and record and EncryptionContext.encryption_available?(did) do
          decrypt_record(did, record)
        else
          record
        end

        # Warm the read cache
        if record do
          ReadCache.put(pzdb_uri, record, result["version"])
        end

        :telemetry.execute([:pzdb, :read, :ok], %{found: result["found"]}, %{uri: pzdb_uri})
        {:ok, %{record: record, version: result["version"], found: result["found"], cached: false}}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp resolve_table_path(pzdb_uri) do
    case PRZMA.PzDb.Uri.parse(pzdb_uri) do
      {:ok, parsed} -> PRZMA.PzDb.Uri.lance_path(@base_path, parsed)
      {:error, _}   -> pzdb_uri  # caller passed a raw path
    end
  end

  defp extract_did(pzdb_uri) do
    case String.split(pzdb_uri, "/", parts: 3) do
      ["pzdb:", "", rest | _] ->
        rest |> String.split("/") |> hd()
      _ -> ""
    end
  end

  defp extract_record_id(pzdb_uri) do
    pzdb_uri |> String.split("/") |> List.last()
  end

  defp encrypt_record(did, record) do
    # Encrypt sensitive string fields before serializing to Lance
    # Non-string fields (timestamps, integers, embeddings) are never encrypted
    record
    |> Enum.reduce(%{}, fn {k, v}, acc ->
        encrypted_val = if should_encrypt_field?(k) and is_binary(v) do
          case EncryptionContext.encrypt(did, "pzdb", v) do
            {:ok, env} -> env
            _          -> v
          end
        else
          v
        end
        Map.put(acc, k, encrypted_val)
      end)
    |> Jason.encode!()
  end

  defp decrypt_record(did, record) when is_map(record) do
    Map.new(record, fn {k, v} ->
      decrypted = if should_encrypt_field?(k) and is_binary(v) do
        case EncryptionContext.decrypt(did, "pzdb", v) do
          {:ok, plain} -> plain
          _            -> v
        end
      else
        v
      end
      {k, decrypted}
    end)
  end
  defp decrypt_record(_did, record), do: record

  # Fields that contain user content and should be encrypted at rest
  @encrypted_fields ~w(title description body body_cas content_cas richtext_cas
                        notes_cas text_cas reflection_text name snippet)

  defp should_encrypt_field?(field) when is_binary(field) do
    field in @encrypted_fields
  end
  defp should_encrypt_field?(field) when is_atom(field) do
    to_string(field) in @encrypted_fields
  end
end
