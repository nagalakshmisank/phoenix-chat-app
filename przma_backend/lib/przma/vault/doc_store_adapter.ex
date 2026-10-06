defmodule Przma.Vault.DocStoreAdapter do
  @moduledoc """
  Przma.Vault.NifAdapter implementation over CouchDB — the CouchDB
  counterpart of LanceLinodeAdapter (which stays untouched).

  Reached ONLY via PzdbConnector -> BackendRouter, so every call here has
  already passed PzdbUri.parse, NamespacePolicy and PzdbAuthorization.

  One CouchDB database per user; document ids come only from
  CouchDocId.from_uri/2 ({namespace}:{space}:{table}[:{record}]) and
  database names only from CouchDbName.from_did/1 — never by hand.

  Tables served here (config :przma, :doc_store_tables):

      vault/private/profile      -> vault:private:profile            (one doc)
      files/{space}/index        -> files:{space}:index:{file_id}    (one doc per file)
      files/cas/cas_meta         -> files:cas:cas_meta:{sha256}      (one doc per unique blob)

  Write semantics:
    * single-doc tables (profile): insert/2 is CREATE-ONLY and returns
      {:error, :already_exists} if the doc exists (registration relies
      on this to be idempotent); merge_insert/3 merges fields.
    * record tables (files index, cas_meta): insert/2 and merge_insert/3
      both UPSERT — same contract as the Lance adapter (PRZMA.PzDb.write
      upserts by id), so Files/CasMeta need no special casing.

  Atomic field operations (used by CasMeta), applied to the CURRENT
  document under its _rev, retried on a CouchDB 409 conflict:
      "$inc"        => %{"ref_count" => 1}          add to a number
      "$add_to_set" => %{"referenced_spaces" => sp}  add to a list once

  S3 JSON mirror (*.couch.json) is written only for tables listed in
  config :przma, :s3_mirror_tables (default: vault/profile only).
  """

  @behaviour Przma.Vault.NifAdapter

  alias Przma.Storage.{CouchClient, CouchDbName, CouchDocId, S3Mirror}
  alias Przma.Vault.PzdbUri

  # One document per (namespace, space, table) for a DID — no record segment.
  @single_doc_tables ~w(profile)
  # Bookkeeping keys that are never stored as document fields.
  @meta_keys ~w(id tier)
  # Envelope fields are always set by this adapter, never by callers.
  @envelope_keys ~w(_id _rev type vault_id namespace space table did gid pzdb_uri doc_ver created_at updated_at)
  # Atomic operations understood by write/6.
  @op_keys ~w($inc $add_to_set)
  @max_conflict_retries 5
  @default_mirror_tables [{"vault", "profile"}]
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
  All documents of this URI's {namespace, space, table} for the URI's
  DID, as a JSON array. Each element carries "id" = the record id (the
  last segment of the CouchDB _id). A user whose database does not
  exist yet simply has no documents -> "[]".
  """
  @impl true
  def query_many(%PzdbUri{namespace: ns, did: did} = uri) do
    with {:ok, table_id} <- CouchDocId.from_uri(uri, nil) do
      prefix = table_id <> ":"

      case CouchClient.list_by_prefix(CouchDbName.from_did(did), ns, prefix, limit: @list_limit) do
        {:ok, docs} -> {:ok, docs |> Enum.map(&to_fields(&1, prefix)) |> Jason.encode!()}
        {:error, :not_found} -> {:ok, "[]"}
        {:error, _} = err -> err
      end
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
    :limit       default 200, capped at #{1000}
    :descending  true = highest id first (newest first)

  Returns the same JSON-array shape as query_many/1.
  """
  def query_range(%PzdbUri{namespace: ns, did: did} = uri, opts) do
    with {:ok, table_id} <- CouchDocId.from_uri(uri, nil) do
      base = table_id <> ":"
      prefix = base <> to_string(Keyword.get(opts, :prefix, ""))
      limit = opts |> Keyword.get(:limit, 200) |> min(@list_limit) |> max(1)
      descending = Keyword.get(opts, :descending, false)
      after_id = Keyword.get(opts, :after)
      before_id = Keyword.get(opts, :before)

      low = if after_id, do: base <> after_id, else: prefix
      high = if before_id, do: base <> before_id, else: prefix <> "\u{FFF0}"
      {startkey, endkey} = if descending, do: {high, low}, else: {low, high}
      excluded = Enum.reject([after_id, before_id], &is_nil/1)

      # +2: the two bounds are inclusive in CouchDB but exclusive here.
      case CouchClient.list_range(CouchDbName.from_did(did), ns, startkey, endkey,
             limit: limit + 2,
             descending: descending
           ) do
        {:ok, docs} ->
          rows =
            docs
            |> Enum.map(&to_fields(&1, base))
            |> Enum.reject(&(&1["id"] in excluded))
            |> Enum.take(limit)

          {:ok, Jason.encode!(rows)}

        {:error, :not_found} ->
          {:ok, "[]"}

        {:error, _} = err ->
          err
      end
    end
  end

  @impl true
  def query_since(%PzdbUri{}, _since), do: {:error, :not_implemented}

  @impl true
  def compact(%PzdbUri{}), do: :ok

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

  defp store(%PzdbUri{} = uri, row, mode, attempt \\ 1) do
    row = stringify_keys(row)
    record_id = record_id(uri, row)

    result =
      with {:ok, db, id} <- locate(uri, record_id) do
        case {mode, CouchClient.get_doc(db, id)} do
          {:create, {:ok, _doc}} -> {:error, :already_exists}
          {_mode, {:ok, doc}} -> write(uri, record_id, db, id, row, doc)
          {_mode, {:error, :not_found}} -> write(uri, record_id, db, id, row, nil)
          {_mode, {:error, _} = err} -> err
        end
      end

    case result do
      # Someone else updated the doc between our read and write (e.g. two
      # uploads of the same file bumping ref_count). Re-read and re-apply.
      {:error, :conflict} when mode == :upsert and attempt < @max_conflict_retries ->
        Process.sleep(10 * attempt)
        store(uri, row, mode, attempt + 1)

      {:error, :conflict} when mode == :create ->
        {:error, :already_exists}

      {:error, :database_not_found} ->
        {:error, :user_vault_not_provisioned}

      other ->
        other
    end
  end

  defp write(%PzdbUri{} = uri, record_id, db, id, row, existing) do
    {ops, row} = Map.split(row, @op_keys)
    fields = Map.drop(row, @meta_keys ++ @envelope_keys)
    previous = if existing, do: Map.drop(existing, @envelope_keys), else: %{}

    doc =
      previous
      |> Map.merge(fields)
      |> apply_inc(Map.get(ops, "$inc", %{}))
      |> apply_add_to_set(Map.get(ops, "$add_to_set", %{}))
      |> Map.merge(envelope(uri, id, existing))

    with {:ok, rev} <- CouchClient.put_doc(db, doc) do
      if mirror?(uri), do: S3Mirror.put(uri, record_id, Map.put(doc, "_rev", rev))
      :ok
    end
  end

  defp apply_inc(doc, incs) do
    Enum.reduce(incs, doc, fn {field, delta}, acc ->
      current = if is_number(acc[field]), do: acc[field], else: 0
      Map.put(acc, to_string(field), current + delta)
    end)
  end

  defp apply_add_to_set(doc, adds) do
    Enum.reduce(adds, doc, fn {field, value}, acc ->
      field = to_string(field)
      current = if is_list(acc[field]), do: acc[field], else: []
      Map.put(acc, field, if(value in current, do: current, else: current ++ [value]))
    end)
  end

  defp mirror?(%PzdbUri{namespace: ns, table: table}) do
    {ns, table} in Application.get_env(:przma, :s3_mirror_tables, @default_mirror_tables)
  end

  # ── read path ────────────────────────────────────────────────────────

  defp read(%PzdbUri{} = uri, record_id) do
    with {:ok, db, id} <- locate(uri, record_id),
         {:ok, doc} <- CouchClient.get_doc(db, id) do
      fields = doc |> Map.drop(["_id", "_rev"]) |> maybe_put_id(record_id)
      {:ok, Jason.encode!(fields)}
    end
  end

  defp to_fields(%{"_id" => doc_id} = doc, prefix) do
    record_id = String.replace_prefix(doc_id, prefix, "")
    doc |> Map.drop(["_id", "_rev"]) |> Map.put("id", record_id)
  end

  defp maybe_put_id(fields, nil), do: fields
  defp maybe_put_id(fields, record_id), do: Map.put(fields, "id", record_id)

  # ── envelope ─────────────────────────────────────────────────────────

  # Envelope fields set on every document. Signatures/encryption
  # (ADR 3.8/3.9) are a later phase.
  defp envelope(%PzdbUri{} = uri, id, existing) do
    now = System.os_time(:microsecond)
    existing = existing || %{}

    %{
      "_id" => id,
      "type" => uri.table,
      "vault_id" => "#{uri.did}/#{uri.space}",
      "namespace" => uri.namespace,
      "space" => uri.space,
      "table" => uri.table,
      "did" => uri.did,
      "gid" => uri.tenant_id,
      "pzdb_uri" => PzdbUri.to_string(uri),
      "doc_ver" => (existing["doc_ver"] || 0) + 1,
      "created_at" => existing["created_at"] || now,
      "updated_at" => now
    }
    |> maybe_put_rev(existing)
  end

  defp maybe_put_rev(doc, %{"_rev" => rev}), do: Map.put(doc, "_rev", rev)
  defp maybe_put_rev(doc, _), do: doc

  # ── helpers ──────────────────────────────────────────────────────────

  defp record_id(%PzdbUri{table: table}, _row) when table in @single_doc_tables, do: nil
  defp record_id(%PzdbUri{}, row), do: row["id"]

  defp locate(%PzdbUri{did: did} = uri, record_id) do
    with {:ok, id} <- CouchDocId.from_uri(uri, record_id) do
      {:ok, CouchDbName.from_did(did), id}
    end
  end

  defp stringify_keys(row) when is_map(row), do: Map.new(row, fn {k, v} -> {to_string(k), v} end)
end
