defmodule Przma.Vault.DocStoreAdapter do
  @moduledoc """
  Przma.Vault.NifAdapter implementation over CouchDB — the CouchDB
  counterpart of LanceLinodeAdapter (which stays untouched).

  Reached ONLY via PzdbConnector -> BackendRouter, so every call here has
  already passed PzdbUri.parse, NamespacePolicy and PzdbAuthorization.

  Lance vs CouchDB for the same pzdb URI:

      pzdb://s3/{tenant}/did:przma:kc_user1/vault/private/profile

      Lance    s3://perkeep/did_przma_kc_user1/vault/private/profile.lance   (row)
      CouchDB  przma_did_przma_kc_user1  →  doc "vault:private:profile"     (fields)
      S3 view  s3://perkeep/did_przma_kc_user1/vault/private/profile.couch.json

  The profile fields are stored IN the CouchDB document (like the row in
  profile.lance). There is no separate data file for the profile.

  Write order: CouchDB first (source of truth), then the S3 JSON mirror
  (see S3Mirror — a mirror failure is logged, never fails the request).

  Semantics (same contract the Lance adapter offers):
    insert/2        create; {:error, :already_exists} if the doc exists
    merge_insert/3  field-level merge into the existing doc (PATCH)
    query/2         the document's fields as a JSON binary
    get_by_id/2     same, for tables with one doc per record id

  Document ids come only from CouchDocId.from_uri/2 and database names
  only from CouchDbName.from_did/1 — never written by hand.
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

  # ── NifAdapter callbacks ─────────────────────────────────────────────

  @impl true
  def open(%PzdbUri{}), do: :ok

  @impl true
  def insert(%PzdbUri{} = uri, rows) when is_list(rows), do: each_row(rows, &store(uri, &1, :create))
  def insert(%PzdbUri{}, _arrow_binary), do: {:error, :arrow_ipc_not_supported}

  @impl true
  def merge_insert(%PzdbUri{} = uri, rows, _on) when is_list(rows), do: each_row(rows, &store(uri, &1, :upsert))
  def merge_insert(%PzdbUri{}, _arrow_binary, _on), do: {:error, :arrow_ipc_not_supported}

  @impl true
  def query(%PzdbUri{} = uri, _opts), do: read(uri, nil)

  @impl true
  def get_by_id(%PzdbUri{} = uri, id), do: read(uri, id)

  @impl true
  def query_many(%PzdbUri{}), do: {:error, :not_implemented}

  @impl true
  def query_since(%PzdbUri{}, _since), do: {:error, :not_implemented}

  @impl true
  def compact(%PzdbUri{}), do: :ok

  @impl true
  def fetch_chunk(%PzdbUri{}, _chunk_address), do: {:error, :not_implemented}

  # ── write path ───────────────────────────────────────────────────────

  defp each_row(rows, fun) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case fun.(row) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp store(%PzdbUri{} = uri, row, mode) do
    row = stringify_keys(row)
    record_id = record_id(uri, row)

    with {:ok, db, id} <- locate(uri, record_id) do
      case {mode, CouchClient.get_doc(db, id)} do
        {:create, {:ok, _doc}} -> {:error, :already_exists}
        {_mode, {:ok, doc}} -> write(uri, record_id, db, id, row, doc)
        {_mode, {:error, :not_found}} -> write(uri, record_id, db, id, row, nil)
        {_mode, {:error, _} = err} -> err
      end
    end
  end

  defp write(%PzdbUri{} = uri, record_id, db, id, row, existing) do
    fields = Map.drop(row, @meta_keys ++ @envelope_keys)
    previous = if existing, do: Map.drop(existing, @envelope_keys), else: %{}

    doc =
      previous
      |> Map.merge(fields)
      |> Map.merge(envelope(uri, id, existing))

    with {:ok, rev} <- CouchClient.put_doc(db, doc) do
      S3Mirror.put(uri, record_id, Map.put(doc, "_rev", rev))
    end
  end

  # ── read path ────────────────────────────────────────────────────────

  defp read(%PzdbUri{} = uri, record_id) do
    with {:ok, db, id} <- locate(uri, record_id),
         {:ok, doc} <- CouchClient.get_doc(db, id) do
      {:ok, doc |> Map.drop(["_id", "_rev"]) |> Jason.encode!()}
    end
  end

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
