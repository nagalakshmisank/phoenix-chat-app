# elixir/lib/przma/pzdb/supervisor.ex
#
# PzDb supervision tree — updated for 100K users.
# WriterPool replaces DynamicSupervisor + per-DID VaultWriter.

defmodule PRZMA.PzDb.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for WriteWorkers (1000 slots)
      {Registry, keys: :unique, name: PRZMA.PzDb.WorkerRegistry},

      # Fixed pool of 1000 write workers (replaces per-DID VaultWriter GenServers)
      PRZMA.PzDb.WriterPool,

      # ETS-backed read cache
      PRZMA.PzDb.ReadCache,

      # Consistent-hash ring router (rebuilds on node up/down)
      PRZMA.PzDb.WriteRouter,

      # Automatic compaction scheduler
      PRZMA.PzDb.Compaction,

      # Circuit breaker with real S3 probe
      PRZMA.PzDb.HealthMonitor,

      # Telemetry handlers
      {PRZMA.PzDb.Telemetry, []},

      # Periodic cache eviction (every 5 minutes)
      {PRZMA.PzDb.CacheEvictTask, []},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.PzDb.CacheEvictTask do
  @moduledoc "Calls Rust cache eviction every 5 minutes to free stale Table handles."
  use GenServer

  @interval_ms 5 * 60 * 1_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:evict, state) do
    PRZMA.Calendar.NIF.pzdb_cache_evict()
    schedule()
    {:noreply, state}
  end

  defp schedule, do: Process.send_after(self(), :evict, @interval_ms)
end

# ─────────────────────────────────────────────────────────────────────────────

# elixir/lib/przma/pzdb/pzdb.ex  (updated — uses WriterPool, not VaultWriter)
#
# PRZMA.PzDb — unified public API for all Lance DB operations.
# Drop-in replacement for the previous PRZMA.PzDb module.

defmodule PRZMA.PzDb do
  alias PRZMA.PzDb.{WriterPool, WriteRouter, ReadCache, HealthMonitor}
  alias PRZMA.Calendar.Storage.EncryptionContext
  alias PRZMA.Calendar.NIF
  alias PRZMA.Platform.MetadataIndex

  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── WRITE ───────────────────────────────────────────────────────────────────

  @doc """
  Write a record to a pzdb:// URI.

  Returns {:ok, write_result} where write_result contains:
    record_id:  written record's id
    version:    Lance manifest version (use as min_version on reads)
    attempts:   OCC retries used (1 = no conflict)
    latency_us: total duration in microseconds

  Passes through the 7-stage write pipeline:
    Health → Encrypt → Route → Worker → NIF(merge_insert) → Cache-invalidate → Index
  """
  def write(pzdb_uri, record, opts \\ []) when is_binary(pzdb_uri) and is_map(record) do
    with :ok <- HealthMonitor.check() do
      start      = System.monotonic_time(:microsecond)
      did        = extract_did(pzdb_uri)
      table_path = lance_path(pzdb_uri)
      key_cols   = opts[:key_columns] || ["id"]
      encrypt?   = Keyword.get(opts, :encrypt, true)

      record_json =
        if encrypt? and EncryptionContext.encryption_available?(did) do
          encrypt_record(did, record)
        else
          Jason.encode!(record)
        end

      result = WriteRouter.write(did, fn ->
        NIF.pzdb_upsert(@base_path, table_path, record_json, Jason.encode!(key_cols))
      end)

      latency = System.monotonic_time(:microsecond) - start

      case result do
        {:ok, json} ->
          wr = Jason.decode!(json)
          ReadCache.invalidate(pzdb_uri)
          maybe_index(did, pzdb_uri, opts[:index_opts])
          HealthMonitor.record_success(latency)
          emit_write_ok(pzdb_uri, wr["attempts"], latency)
          {:ok, wr}

        {:error, :backpressure} = err ->
          emit_write_rejected(pzdb_uri)
          err

        {:error, msg} ->
          HealthMonitor.record_error(msg)
          emit_write_err(pzdb_uri)
          {:error, msg}
      end
    end
  end

  @doc "Write multiple records to the same table atomically."
  def batch_write(pzdb_table_uri, records, opts \\ []) do
    with :ok <- HealthMonitor.check() do
      did        = extract_did(pzdb_table_uri)
      table_path = lance_path(pzdb_table_uri)
      key_cols   = opts[:key_columns] || ["id"]

      WriteRouter.write(did, fn ->
        NIF.pzdb_batch_upsert(
          @base_path, table_path,
          Jason.encode!(records),
          Jason.encode!(key_cols)
        )
      end)
      |> case do
        {:ok, json}   -> {:ok, Jason.decode!(json)}
        {:error, _}   = err -> err
      end
    end
  end

  @doc "Soft-delete a record (stamps deleted_at, does not remove from Lance)."
  def delete(pzdb_uri, deleted_by) when is_binary(pzdb_uri) do
    with :ok <- HealthMonitor.check() do
      did        = extract_did(pzdb_uri)
      table_path = lance_path(pzdb_uri)
      record_id  = extract_record_id(pzdb_uri)

      WriteRouter.write(did, fn ->
        NIF.pzdb_soft_delete(@base_path, table_path, record_id, deleted_by)
      end)
      |> case do
        {:ok, json} ->
          ReadCache.invalidate(pzdb_uri)
          MetadataIndex.deindex(did, pzdb_uri)
          {:ok, Jason.decode!(json)}
        {:error, _} = err -> err
      end
    end
  end

  # ── READ ────────────────────────────────────────────────────────────────────

  @doc """
  Read a record by pzdb:// URI.
  Returns {:ok, %{record: map, version: n, found: bool, cached: bool}}

  Options:
    min_version:  ensure read sees at least this Lance version (read-after-write)
    skip_cache:   bypass ETS read cache
    decrypt:      boolean (default true)
  """
  def read(pzdb_uri, opts \\ []) when is_binary(pzdb_uri) do
    min_version = opts[:min_version] || 0
    skip_cache  = opts[:skip_cache]  || false
    decrypt?    = Keyword.get(opts, :decrypt, true)
    did         = extract_did(pzdb_uri)

    if not skip_cache and min_version == 0 do
      case ReadCache.get(pzdb_uri) do
        {:hit, record, version} ->
          emit_cache_hit(pzdb_uri)
          {:ok, %{record: record, version: version, found: true, cached: true}}
        :miss ->
          do_read(pzdb_uri, did, min_version, decrypt?)
      end
    else
      do_read(pzdb_uri, did, min_version, decrypt?)
    end
  end

  @doc "Query multiple records with a filter."
  def query(pzdb_table_uri, opts \\ []) when is_binary(pzdb_table_uri) do
    table_path  = lance_path(pzdb_table_uri)
    filter      = opts[:filter]      || ""
    limit       = opts[:limit]       || 100
    min_version = opts[:min_version] || 0

    case NIF.pzdb_read_many(@base_path, table_path, filter, limit, min_version) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Get the current manifest version for a pzdb table URI."
  def version(pzdb_table_uri) when is_binary(pzdb_table_uri) do
    table_path = lance_path(pzdb_table_uri)
    case NIF.pzdb_version(@base_path, table_path) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── FAN-OUT ─────────────────────────────────────────────────────────────────

  @doc """
  Write the same logical record to multiple DIDs' vaults in parallel.
  Each write is routed to its home node and writer independently.
  Partial failures are collected, not raised.
  Returns %{succeeded: [{uri, result}], failed: [{uri, reason}]}
  """
  def fan_out(uri_record_pairs, opts \\ []) when is_list(uri_record_pairs) do
    concurrency = opts[:concurrency] || 10
    timeout_ms  = opts[:timeout_ms]  || 15_000

    {ok_list, err_list} = uri_record_pairs
      |> Task.async_stream(
          fn {pzdb_uri, record} -> {pzdb_uri, write(pzdb_uri, record, opts)} end,
          max_concurrency: concurrency,
          timeout:         timeout_ms,
          on_timeout:      :kill_task
        )
      |> Enum.reduce({[], []}, fn
          {:ok, {uri, {:ok, r}}},  {ok, err} -> {[{uri, r} | ok], err}
          {:ok, {uri, {:error, m}}},{ok, err} -> {ok, [{uri, m} | err]}
          {:exit, {uri, :timeout}}, {ok, err} -> {ok, [{uri, :timeout} | err]}
          _,                        {ok, err} -> {ok, err}
        end)

    %{succeeded: Enum.reverse(ok_list), failed: err_list}
  end

  # ── TABLE MANAGEMENT ────────────────────────────────────────────────────────

  @doc "Provision a Lance table if it doesn't exist. Idempotent."
  def ensure_table(pzdb_table_uri, schema_name) when is_binary(pzdb_table_uri) do
    table_path = lance_path(pzdb_table_uri)
    case NIF.pzdb_provision_table(@base_path, table_path, schema_name) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc """
  Provision all 24 standard Lance tables for a DID.
  Called once on user account creation. Idempotent — safe to call on startup.
  """
  def provision_vault(did) do
    tables = standard_tables()
    results = Enum.map(tables, fn {path, schema} ->
      uri = "pzdb://#{did}/#{path}/placeholder"
      {path, ensure_table(uri, schema)}
    end)
    failed = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)
    if Enum.empty?(failed),
      do:   {:ok, %{tables_provisioned: length(tables)}},
      else: {:error, %{failed: failed}}
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────────────

  defp do_read(pzdb_uri, did, min_version, decrypt?) do
    table_path = lance_path(pzdb_uri)
    record_id  = extract_record_id(pzdb_uri)

    case NIF.pzdb_read(@base_path, table_path, record_id, min_version) do
      {:ok, json} ->
        result = Jason.decode!(json)
        record = if decrypt? and result["record"] and EncryptionContext.encryption_available?(did) do
          decrypt_record(did, result["record"])
        else
          result["record"]
        end
        if record, do: ReadCache.put(pzdb_uri, record, result["version"])
        {:ok, %{record: record, version: result["version"], found: result["found"], cached: false}}
      {:error, msg} ->
        {:error, msg}
    end
  end

  defp lance_path(pzdb_uri) do
    case PRZMA.PzDb.Uri.parse(pzdb_uri) do
      {:ok, parsed} -> PRZMA.PzDb.Uri.lance_path(@base_path, parsed)
      {:error, _}   -> pzdb_uri
    end
  end

  defp extract_did("pzdb://" <> rest) do
    rest |> String.split("/", parts: 2) |> hd()
  end
  defp extract_did(_), do: ""

  defp extract_record_id(uri) do
    uri |> String.split("/") |> List.last()
  end

  defp encrypt_record(did, record) do
    record
    |> Enum.reduce(%{}, fn {k, v}, acc ->
        val = if should_encrypt?(k) and is_binary(v) do
          case EncryptionContext.encrypt(did, "pzdb", v) do
            {:ok, env} -> env
            _          -> v
          end
        else
          v
        end
        Map.put(acc, k, val)
      end)
    |> Jason.encode!()
  end

  defp decrypt_record(did, record) when is_map(record) do
    Map.new(record, fn {k, v} ->
      val = if should_encrypt?(k) and is_binary(v) do
        case EncryptionContext.decrypt(did, "pzdb", v) do
          {:ok, plain} -> plain
          _            -> v
        end
      else
        v
      end
      {k, val}
    end)
  end
  defp decrypt_record(_did, record), do: record

  @encrypted_fields ~w(title description body body_cas content_cas richtext_cas
                        notes_cas text_cas name snippet reflection_text)

  defp should_encrypt?(field) when is_binary(field), do: field in @encrypted_fields
  defp should_encrypt?(field) when is_atom(field),   do: to_string(field) in @encrypted_fields

  defp maybe_index(did, uri, nil), do: :ok
  defp maybe_index(did, uri, opts) do
    Task.start(fn -> MetadataIndex.index(did, uri, Map.to_list(opts)) end)
  end

  defp emit_write_ok(uri, attempts, latency),
    do: :telemetry.execute([:pzdb, :write, :ok], %{latency_us: latency, attempts: attempts}, %{uri: uri})
  defp emit_write_rejected(uri),
    do: :telemetry.execute([:pzdb, :write, :rejected], %{count: 1}, %{uri: uri})
  defp emit_write_err(uri),
    do: :telemetry.execute([:pzdb, :write, :error], %{count: 1}, %{uri: uri})
  defp emit_cache_hit(uri),
    do: :telemetry.execute([:pzdb, :read, :cache_hit], %{count: 1}, %{uri: uri})

  defp standard_tables do
    ~w(
      vault/core/entries           entries
      vault/core/practice_logs     practice_logs
      calendar/core/events         events
      calendar/core/tasks          tasks
      calendar/core/availability   availability
      calendar/core/booking_links  booking_links
      calendar/core/reminders      reminders
      calendar/core/transcripts    transcripts
      chat/core/messages           messages
      chat/core/threads            threads
      files/core/files             files
      metadata/core/search_index   search_index
      metadata/core/references     references
      metadata/core/tags           tags
      ai/core/model_registry       model_registry
      ai/core/inference_log        inference_log
      agents/core/sessions         sessions
      creative/core/projects       projects
      companion/core/memories      memories
      companion/core/sapience_snapshots sapience_snapshots
      companion/core/arc_timeline  arc_timeline
      social/core/memberships      memberships
      social/core/followers        followers
    )
    |> Enum.chunk_every(2)
    |> Enum.map(fn [path, schema] -> {path, schema} end)
  end
end
