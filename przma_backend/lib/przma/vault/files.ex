defmodule Przma.Vault.Files do
  @moduledoc """
  File service — namespace "files", three user spaces plus the internal
  CAS folder:

      files/private/   file metadata, owner-only by default (grantable later)
      files/personal/  file metadata, never grantable
      files/public/    file metadata, shareable; CAS metadata also copied to Postgres
      files/cas/       the CAS ledger (one doc per unique hash) + the bytes in S3

  Where everything lands (user kc_user1):

      S3       perkeep/did_przma_kc_user1/files/cas/ab/ab12…ef     original bytes, once per hash
      CouchDB  przma_did_przma_kc_user1
                 files:{space}:index:{file_id}                      one doc per uploaded file
                 files:cas:cas_meta:{sha256}                        one doc per unique hash
      Postgres przma_commons_cas.cas_table                          PUBLIC files only (did + hash)

  Upload order (upload/5), every step authorized via the pzdb URI:
    1. Cas.put/3          authorize (files, space) -> bytes to S3 (dedup by hash)
    2. CasMeta.record/6   CAS ledger doc: ref_count +1 (atomic), referenced_spaces
    3. index document     file metadata in files:{space}:index:{file_id}
    4. public only        Przma.CommonsCas.Replicator -> Postgres cas_table

  The Postgres copy is best-effort (never fails the upload) but NOT
  silent: its outcome is returned as `commons` ("replicated", "skipped"
  or "failed: …") and logged at error level on failure. It runs for all
  three upload paths: upload/5, upload_blob/4 and sync_record/5.
  """

  require Logger

  alias Przma.CommonsCas.Replicator
  alias Przma.Vault.{Cas, CasMeta, PzdbConnector, PzdbUri}

  @namespace "files"
  @table "index"
  @default_space "private"
  @public_space "public"

  @type file_metadata :: %{
          filename: String.t(),
          content_type: String.t() | nil,
          size_bytes: integer()
        }

  @type upload_result :: %{
          file_id: String.t(),
          content_cas: String.t(),
          ref_count: non_neg_integer(),
          commons: String.t()
        }

  @doc """
  Uploads bytes + indexes them into `owner_did`'s files/`space`.
  `owner_did` and `space` default to the actor's own did and "private".
  """
  @spec upload(PzdbConnector.actor(), String.t(), binary(), file_metadata(), keyword()) ::
          {:ok, upload_result()} | {:error, term()}
  def upload(%{did: actor_did} = actor, tenant_uuid, bytes, metadata, opts \\ []) when is_binary(bytes) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    size_bytes = byte_size(bytes)
    mime_type = metadata[:content_type] || "application/octet-stream"

    with {:ok, content_cas} <- Cas.put(actor, uri, bytes) do
      ref_count = record_cas_meta(actor, tenant_uuid, owner_did, content_cas, size_bytes, space)
      file_id = generate_file_id()

      row = %{
        id: file_id,
        did: owner_did,
        gid: tenant_uuid,
        name: metadata.filename,
        mime_type: mime_type,
        size_bytes: metadata[:size_bytes] || size_bytes,
        content_cas: content_cas,
        created_at: System.os_time(:microsecond)
      }

      with :ok <- PzdbConnector.write(actor, PzdbUri.to_string(uri), [row]) do
        commons = replicate_if_public(space, owner_did, actor.did, content_cas, mime_type, size_bytes, ref_count)
        {:ok, %{file_id: file_id, content_cas: content_cas, ref_count: ref_count, commons: commons}}
      end
    end
  end

  @doc """
  Content-only upload — Cas.put/3 + the CAS ledger bump, WITHOUT an
  index document (offline clients sync the record later via
  sync_record/5). Public uploads are copied to Postgres here too.
  Opts: :space, :owner_did, :content_type.
  """
  @spec upload_blob(PzdbConnector.actor(), String.t(), binary(), keyword()) ::
          {:ok, %{content_cas: String.t(), size_bytes: integer(), ref_count: integer(), commons: String.t()}}
          | {:error, term()}
  def upload_blob(%{did: actor_did} = actor, tenant_uuid, bytes, opts \\ []) when is_binary(bytes) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    mime_type = Keyword.get(opts, :content_type) || "application/octet-stream"
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    size_bytes = byte_size(bytes)

    with {:ok, content_cas} <- Cas.put(actor, uri, bytes),
         {:ok, ref_count} <- CasMeta.record(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
      commons = replicate_if_public(space, owner_did, actor.did, content_cas, mime_type, size_bytes, ref_count)
      {:ok, %{content_cas: content_cas, size_bytes: size_bytes, ref_count: ref_count, commons: commons}}
    end
  end

  @doc """
  Record-only sync — writes just the index document for a `content_cas`
  whose bytes were already uploaded via upload_blob/4. Does NOT bump the
  ledger again (the blob upload already counted it). If the record is
  public, the CAS metadata is (re)copied to Postgres.
  """
  @spec sync_record(PzdbConnector.actor(), String.t(), String.t(), file_metadata(), keyword()) ::
          {:ok, %{file_id: String.t(), commons: String.t()}} | {:error, term()}
  def sync_record(%{did: actor_did} = actor, tenant_uuid, content_cas, metadata, opts \\ []) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    file_id = Keyword.get(opts, :file_id) || generate_file_id()
    mime_type = metadata[:content_type] || "application/octet-stream"

    row = %{
      id: file_id,
      did: owner_did,
      gid: tenant_uuid,
      name: metadata.filename,
      mime_type: mime_type,
      size_bytes: metadata[:size_bytes] || 0,
      content_cas: content_cas,
      created_at: System.os_time(:microsecond)
    }

    with :ok <- PzdbConnector.write(actor, PzdbUri.to_string(uri), [row]) do
      commons =
        if space == @public_space do
          {size, ref_count} = ledger_size_and_count(actor, tenant_uuid, owner_did, content_cas, row.size_bytes)
          replicate_if_public(space, owner_did, actor.did, content_cas, mime_type, size, ref_count)
        else
          "skipped"
        end

      {:ok, %{file_id: file_id, commons: commons}}
    end
  end

  @doc "Lists file metadata documents for `owner_did`'s `space` (defaults: actor's own, \"private\")."
  @spec list_recent(PzdbConnector.actor(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def list_recent(%{did: actor_did} = actor, tenant_uuid, opts \\ []) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    PzdbConnector.read_many(actor, PzdbUri.to_string(uri))
  end

  @doc "Downloads content bytes for a known content_cas (Cas.get/3 authorizes against the space)."
  @spec download(PzdbConnector.actor(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def download(actor, tenant_uuid, owner_did, content_cas, opts \\ []) do
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    Cas.get(actor, uri, content_cas)
  end

  @doc "Presigned, short-lived S3 GET URL for a known content_cas (authorized against the space)."
  @spec download_url(PzdbConnector.actor(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def download_url(actor, tenant_uuid, owner_did, content_cas, opts \\ []) do
    space = Keyword.get(opts, :space, @default_space)
    expires_in = Keyword.get(opts, :expires_in, 300)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    Cas.presigned_get_url(actor, uri, content_cas, expires_in: expires_in)
  end

  # ── private ───────────────────────────────────────────────────────────

  defp build_pzdb_uri(tenant_uuid, did, space) do
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, space: space, table: @table}
  end

  defp generate_file_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # Best-effort — a ledger hiccup never fails an upload whose bytes are
  # already in S3. Returns the ref_count (1 if the ledger write failed).
  defp record_cas_meta(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
    case CasMeta.record(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
      {:ok, ref_count} ->
        ref_count

      {:error, reason} ->
        Logger.error("[Files] CAS ledger write failed did=#{owner_did} hash=#{content_cas} reason=#{inspect(reason)}")
        1
    end
  end

  defp ledger_size_and_count(actor, tenant_uuid, owner_did, content_cas, fallback_size) do
    case CasMeta.get(actor, tenant_uuid, owner_did, content_cas) do
      {:ok, doc} -> {doc["size_bytes"] || fallback_size, doc["ref_count"] || 1}
      {:error, _} -> {fallback_size, 1}
    end
  end

  defp replicate_if_public(@public_space, owner_did, created_by, content_cas, mime_type, size_bytes, ref_count) do
    attrs = %{
      hash: content_cas,
      did: owner_did,
      created_by: created_by,
      file_origin: owner_did,
      mime_type: mime_type,
      size_bytes: size_bytes,
      ref_count: ref_count,
      is_encrypted: false,
      s3_uri: CasMeta.internal_s3_uri(owner_did, content_cas)
    }

    case Replicator.replicate(attrs) do
      :ok -> "replicated"
      {:error, reason} -> "failed: " <> reason_text(reason)
    end
  end

  defp replicate_if_public(_space, _owner, _by, _cas, _mime, _size, _ref_count), do: "skipped"

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason), do: inspect(reason)
end
