defmodule Przma.Vault.LanceDocAdapter do
  @moduledoc """
  Przma.Vault.NifAdapter implementation over LanceDB tables in S3 — the
  replacement for the CouchDB DocStoreAdapter. Same callbacks, same
  return shapes, so no service, resolver or GraphQL type changes.

  Reached ONLY via PzdbConnector -> BackendRouter, so every call here has
  already passed PzdbUri.parse, NamespacePolicy and PzdbAuthorization.

  WHERE (one .lance table per {did, namespace, space, table}):

      vault/private/profile   -> s3://perkeep/did_…/vault/private/profile.lance   (one row, id = did)
      files/{space}/index     -> s3://perkeep/did_…/files/{space}/index.lance    (one row per file)
      files/cas/cas_meta      -> s3://perkeep/did_…/files/cas/cas_meta.lance     (one row per sha256)
      chat/private/inbox      -> s3://perkeep/did_…/chat/private/inbox.lance     (one row per message)
      …                          every {namespace, table} in config :doc_store_tables

  ROW LAYOUT (doc_schema in lib.rs): envelope columns id, did, gid,
  namespace, space, table_name, pzdb_uri, doc_ver, created_at, updated_at,
  plus `doc_json` = every other field. Reads return the same flat map the
  CouchDB adapter returned (fields + envelope; "id" for record tables).

  WRITE SEMANTICS (unchanged from the CouchDB adapter):
    * single-doc tables (profile): insert/2 is CREATE-ONLY and returns
      {:error, :already_exists} if the row exists (registration relies on
      this to be idempotent); merge_insert/3 merges fields.
    * record tables: insert/2 and merge_insert/3 both UPSERT and MERGE —
      fields not mentioned are kept.
    * atomic field operations:
        "$inc"        => %{"ref_count" => 1}          add to a number
        "$add_to_set" => %{"referenced_spaces" => sp}  add to a list once
      Atomic because the read-modify-write runs inside the user's
      DocWriter (one write at a time per user) instead of CouchDB's _rev.

  Each write is one Lance commit (merge_insert on id). After it, the table
  is marked dirty for LanceCompactor.
  """

  @behaviour Przma.Vault.NifAdapter

  require Logger

  alias Przma.Storage.{DocKey, DocWriter, LanceCompactor, LanceDocPath}
  alias Przma.Vault.PzdbUri

  # One row per (namespace, space, table) for a DID — no record id.
  @single_doc_tables ~w(profile)
  # Bookkeeping keys that are never stored as document fields.
  @meta_keys ~w(id tier)
  # Envelope fields are always set by this adapter, never by callers.
  @envelope_keys ~w(_id _rev type vault_id namespace space table did gid pzdb_uri doc_ver created_at updated_at)
  # Atomic operations understood by build_row/5.
  @op_keys ~w($inc $add_to_set)
  # query_many/1 returns at most this many rows (same as the CouchDB adapter).
  @list_limit 1000

  # ── NifAdapter callbacks ─────────────────────────────────────────────

  @impl true
  def open(%PzdbUri{}), do: :ok

  @impl true
  def insert(%PzdbUri{} = uri, rows) when is_list(rows), do: each_row(rows, &store(uri, &1, insert_mode(uri)))
  def insert(%PzdbUri{}, _arrow_binary), do: {:error, :arrow_ipc_not_supported}

  @impl true
  def merge_insert(%PzdbUri{} = uri, rows, _on) when is_list(rows), do: each_row(rows, &store(uri, &1, :upsert))
  def merge_insert(%PzdbUri{}, _arrow_binary, _on), do: {:error, :arrow_ipc_not_supported}

  @impl true
  def query(%PzdbUri{} = uri, _opts), do: read(uri, nil)

  @impl true
  def get_by_id(%PzdbUri{} = uri, id), do: read(uri, id)

  @doc """
  All rows of this URI's {namespace, space, table} for the URI's DID, as a
  JSON array sorted by record id (at most #{@list_limit}). Each element
  carries "id" = the record id. A table that does not exist yet -> "[]".
  """
  @impl true
  def query_many(%PzdbUri{} = uri) do
    with :ok <- DocKey.validate(uri, nil),
         {:ok, rows} <- fetch(uri, "") do
      {:ok, rows |> Enum.sort_by(& &1["id"]) |> Enum.take(@list_limit) |> Enum.map(&to_fields(uri, &1)) |> Jason.encode!()}
    end
  end

  @doc """
  Ordered, paged read of one table (NOT part of the NifAdapter behaviour —
  PzdbConnector.read_range/3 calls it only when the adapter exports it).
  Record ids sort as plain text, so tables that need time order use
  time-sortable ids (see Przma.Social.Key).

  Options:
    :prefix      only record ids starting with this (e.g. one chat thread)
    :after       record id — return ids greater than this (exclusive)
    :before      record id — return ids smaller than this (exclusive)
    :limit       default 200, capped at #{@list_limit}
    :descending  true = highest id first (newest first)

  Lance has no ordered key scan: the id range is pushed down as a filter,
  the matching rows are sorted here, then `limit` is applied. Cost grows
  with the size of the range (e.g. one whole chat thread), not with `limit`.

  Returns the same JSON-array shape as query_many/1.
  """
  def query_range(%PzdbUri{} = uri, opts) do
    prefix = to_string(Keyword.get(opts, :prefix, ""))
    after_id = Keyword.get(opts, :after)
    before_id = Keyword.get(opts, :before)
    limit = opts |> Keyword.get(:limit, 200) |> min(@list_limit) |> max(1)
    descending = Keyword.get(opts, :descending, false)

    with :ok <- DocKey.validate(uri, nil),
         :ok <- check_bound(prefix),
         :ok <- check_bound(after_id),
         :ok <- check_bound(before_id),
         {:ok, rows} <- fetch(uri, range_filter(prefix, after_id, before_id)) do
      sorted = Enum.sort_by(rows, & &1["id"], if(descending, do: :desc, else: :asc))
      {:ok, sorted |> Enum.take(limit) |> Enum.map(&to_fields(uri, &1)) |> Jason.encode!()}
    end
  end

  @doc "Rows changed after `since` (updated_at), oldest change first — the timestamp-cursor sync read."
  @impl true
  def query_since(%PzdbUri{} = uri, %DateTime{} = since) do
    micros = DateTime.to_unix(since, :microsecond)

    with :ok <- DocKey.validate(uri, nil),
         {:ok, rows} <- fetch(uri, "updated_at > #{micros}") do
      {:ok, rows |> Enum.sort_by(& &1["updated_at"]) |> Enum.map(&to_fields(uri, &1)) |> Jason.encode!()}
    end
  end

  def query_since(%PzdbUri{}, _since), do: {:error, :invalid_since}

  @doc "Compacts this table now (also done automatically by LanceCompactor)."
  @impl true
  def compact(%PzdbUri{did: did} = uri) do
    with :ok <- DocKey.validate(uri, nil),
         {:ok, _stats} <- LanceCompactor.compact_table(did, LanceDocPath.table_uri(uri)) do
      :ok
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  @impl true
  def fetch_chunk(%PzdbUri{}, _chunk_address), do: {:error, :not_implemented}

  # ── write path ───────────────────────────────────────────────────────

  defp insert_mode(%PzdbUri{table: table}) when table in @single_doc_tables, do: :create
  defp insert_mode(%PzdbUri{}), do: :upsert

  defp each_row(rows, fun) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case fun.(row) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp store(%PzdbUri{did: did} = uri, row, mode) do
    row = stringify_keys(row)
    record_id = record_id(uri, row)

    with :ok <- DocKey.validate(uri, record_id),
         :ok <- require_record_id(uri, record_id) do
      table_uri = LanceDocPath.table_uri(uri)
      id = storage_id(uri, record_id)

      # Everything from the read to the commit happens inside the user's
      # DocWriter, so no other write to this user's tables can interleave.
      DocWriter.run(did, fn ->
        with {:ok, existing} <- fetch_one(table_uri, id),
             :ok <- check_create(mode, existing),
             new_row = build_row(uri, id, row, existing),
             {:ok, _} <- PRZMA.PzDb.doc_upsert(table_uri, [new_row]) do
          LanceCompactor.mark_dirty(did, table_uri)
          :ok
        else
          {:error, reason} -> {:error, normalize_error(reason)}
        end
      end)
    end
  end

  defp check_create(:create, existing) when is_map(existing), do: {:error, :already_exists}
  defp check_create(_mode, _existing), do: :ok

  defp build_row(%PzdbUri{} = uri, id, row, existing) do
    {ops, row} = Map.split(row, @op_keys)
    fields = Map.drop(row, @meta_keys ++ @envelope_keys)
    previous = if existing, do: decode_doc(existing), else: %{}
    now = System.os_time(:microsecond)

    doc =
      previous
      |> Map.merge(fields)
      |> apply_inc(Map.get(ops, "$inc", %{}))
      |> apply_add_to_set(Map.get(ops, "$add_to_set", %{}))

    %{
      "id" => id,
      "did" => uri.did,
      "gid" => uri.tenant_id,
      "namespace" => uri.namespace,
      "space" => uri.space,
      "table_name" => uri.table,
      "pzdb_uri" => PzdbUri.to_string(uri),
      "doc_ver" => ((existing && existing["doc_ver"]) || 0) + 1,
      "created_at" => (existing && existing["created_at"]) || now,
      "updated_at" => now,
      "doc_json" => Jason.encode!(doc)
    }
  end

  defp apply_inc(doc, incs) do
    Enum.reduce(incs, doc, fn {field, delta}, acc ->
      field = to_string(field)
      current = if is_number(acc[field]), do: acc[field], else: 0
      Map.put(acc, field, current + delta)
    end)
  end

  defp apply_add_to_set(doc, adds) do
    Enum.reduce(adds, doc, fn {field, value}, acc ->
      field = to_string(field)
      current = if is_list(acc[field]), do: acc[field], else: []
      Map.put(acc, field, if(value in current, do: current, else: current ++ [value]))
    end)
  end

  # ── read path ────────────────────────────────────────────────────────

  defp read(%PzdbUri{} = uri, record_id) do
    with :ok <- DocKey.validate(uri, record_id),
         {:ok, row} when is_map(row) <- fetch_one(LanceDocPath.table_uri(uri), storage_id(uri, record_id)) do
      {:ok, Jason.encode!(to_fields(uri, row))}
    else
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp fetch_one(table_uri, id) do
    case PRZMA.PzDb.doc_query(table_uri, "id = '#{escape(id)}'", 1) do
      {:ok, %{"records" => [row | _]}} -> {:ok, row}
      {:ok, _} -> {:ok, nil}
      {:error, _} = err -> err
    end
  end

  # Unordered rows matching `filter`, at most query_max_rows.
  defp fetch(%PzdbUri{} = uri, filter) do
    max = cfg(:query_max_rows, 100_000)

    case PRZMA.PzDb.doc_query(LanceDocPath.table_uri(uri), filter, max) do
      {:ok, %{"records" => rows}} when is_list(rows) ->
        if length(rows) >= max do
          Logger.warning("Lance read hit query_max_rows (#{max}) on #{LanceDocPath.location(uri)} — results may be incomplete")
        end

        {:ok, rows}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, normalize_error(reason)}
    end
  end

  # Lance row -> the flat map callers got from CouchDB (fields + envelope).
  defp to_fields(%PzdbUri{} = uri, row) do
    envelope = %{
      "type" => row["table_name"],
      "vault_id" => "#{row["did"]}/#{row["space"]}",
      "namespace" => row["namespace"],
      "space" => row["space"],
      "table" => row["table_name"],
      "did" => row["did"],
      "gid" => row["gid"],
      "pzdb_uri" => row["pzdb_uri"],
      "doc_ver" => row["doc_ver"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"]
    }

    fields = row |> decode_doc() |> Map.merge(envelope)
    if uri.table in @single_doc_tables, do: fields, else: Map.put(fields, "id", row["id"])
  end

  defp decode_doc(%{"doc_json" => json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} -> doc
      _ -> %{}
    end
  end

  defp decode_doc(_), do: %{}

  # ── range filter ─────────────────────────────────────────────────────

  defp range_filter(prefix, after_id, before_id) do
    [
      if(prefix != "", do: "id >= '#{escape(prefix)}'"),
      if(prefix != "", do: "id < '#{escape(prefix_end(prefix))}'"),
      if(after_id, do: "id > '#{escape(after_id)}'"),
      if(before_id, do: "id < '#{escape(before_id)}'")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" AND ")
  end

  # Smallest string greater than every string starting with `prefix`.
  # Record ids are ASCII (DocKey), so bumping the last byte is enough.
  defp prefix_end(prefix) do
    size = byte_size(prefix) - 1
    <<head::binary-size(size), last>> = prefix
    head <> <<last + 1>>
  end

  defp check_bound(nil), do: :ok
  defp check_bound(""), do: :ok
  defp check_bound(value) when is_binary(value), do: if(DocKey.valid_record?(value), do: :ok, else: {:error, :invalid_range_bound})
  defp check_bound(_), do: {:error, :invalid_range_bound}

  # ── helpers ──────────────────────────────────────────────────────────

  defp record_id(%PzdbUri{table: table}, _row) when table in @single_doc_tables, do: nil
  defp record_id(%PzdbUri{}, row), do: row["id"]

  defp require_record_id(%PzdbUri{table: table}, _id) when table in @single_doc_tables, do: :ok
  defp require_record_id(%PzdbUri{}, id) when is_binary(id) and id != "", do: :ok
  defp require_record_id(%PzdbUri{}, _id), do: {:error, :missing_record_id}

  # Value of the `id` column. Single-doc tables: the owner's did.
  defp storage_id(%PzdbUri{did: did, table: table}, _record_id) when table in @single_doc_tables, do: did
  defp storage_id(%PzdbUri{}, record_id), do: record_id

  defp normalize_error("schema_mismatch" <> _ = msg), do: {:table_schema_mismatch, msg}
  defp normalize_error(reason), do: reason

  defp escape(s), do: String.replace(to_string(s), "'", "''")

  defp stringify_keys(row) when is_map(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)

  defp cfg(key, default), do: Keyword.get(Application.get_env(:przma, :lance_doc, []), key, default)
end
