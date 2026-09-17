defmodule Przma.Vault.Files do
  @moduledoc """
  File upload/download for the "files" namespace, across its 3 spaces:
    - "private" (default) — owner-only by default, but grantable in
      principle once live_grant_for/2 is implemented
    - "public" — shareable
    - "personal" — absolute, never grantable under any circumstance
      (NamespacePolicy.personal_space?/1), same guarantee as vault's
      own personal space

  Three writes per upload, in this ORDER, all gated:
    1. CONTENT — Cas.put/3 authorizes actor against the target space
       BEFORE writing any bytes to S3 — nothing is written unless the
       actor is actually allowed to write into that space.
    2. CAS LEDGER — CasMeta.record/6 bumps (or creates) the dedup
       ref-count row for this hash. Failure here is logged but never
       fails the upload — the ledger is a bookkeeping/GC aid, not the
       source of truth for whether the blob or the file record exist.
    3. METADATA — one row via PzdbConnector, which authorizes again
       (same check, cheap, harmless to repeat) before the row lands.

  Content is deduplicated per-DID across all 3 spaces (see Cas
  moduledoc) — the metadata row is what's actually access-controlled
  per space; the physical bytes have no per-space copy at all. The
  CAS ledger (CasMeta) mirrors that: one row per unique hash per DID,
  independent of space, `ref_count` incremented on every reference
  regardless of which space made it.
  """

  require Logger

  alias Przma.Vault.{Cas, CasMeta, PzdbAuthorization, PzdbConnector, PzdbUri}

  @namespace "files"
  @table "index"
  @default_space "private"

  @type file_metadata :: %{
          filename: String.t(),
          content_type: String.t() | nil,
          size_bytes: integer()
        }

  @doc """
  Uploads bytes + indexes them into `owner_did`'s files/`space`.
  `owner_did` and `space` default to the actor's own did and
  "private" — the normal case, which needs no grant at all (owner
  bypass). Pass a different `owner_did` for cross-user access, or
  `space: "public"`/`"personal"` to target a different space.
  """
  @spec upload(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          bytes :: binary(),
          file_metadata(),
          opts :: keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def upload(%{did: actor_did} = actor, tenant_uuid, bytes, metadata, opts \\ []) when is_binary(bytes) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)

    with {:ok, content_cas} <- Cas.put(actor, uri, bytes) do
      ref_count = record_cas_meta(actor, tenant_uuid, owner_did, content_cas, byte_size(bytes), space)
      maybe_replicate_to_commons(owner_did, actor.did, content_cas, metadata, byte_size(bytes), ref_count, space, uri)

      row_id = generate_file_id()

      row = %{
        id: row_id,
        did: owner_did,
        gid: tenant_uuid,
        name: metadata.filename,
        mime_type: metadata[:content_type] || "application/octet-stream",
        size_bytes: metadata[:size_bytes] || byte_size(bytes),
        content_cas: content_cas,
        created_at: System.os_time(:microsecond)
      }

      case PzdbConnector.write(actor, PzdbUri.to_string(uri), [row]) do
        :ok -> {:ok, row_id}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Content-only upload — Cas.put/3 + the CAS ledger bump, deliberately
  WITHOUT an `index` row. GraphQL counterpart to the old REST
  `POST /sync/blob`: offline clients that upload bytes first and sync
  the file record separately (see sync_record/6) once connectivity/
  the rest of the metadata is available. `upload/5` above remains the
  one-shot path (content + record together) for the normal case.
  """
  @spec upload_blob(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          bytes :: binary(),
          opts :: keyword()
        ) :: {:ok, %{content_cas: String.t(), size_bytes: integer(), ref_count: integer()}} | {:error, term()}
  def upload_blob(%{did: actor_did} = actor, tenant_uuid, bytes, opts \\ []) when is_binary(bytes) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    size_bytes = byte_size(bytes)

    with {:ok, content_cas} <- Cas.put(actor, uri, bytes),
         {:ok, ref_count} <- CasMeta.record(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
      {:ok, %{content_cas: content_cas, size_bytes: size_bytes, ref_count: ref_count}}
    end
  end

  @doc """
  Record-only sync — writes just the `index` row for a `content_cas`
  hash whose bytes were already uploaded via upload_blob/4. GraphQL
  counterpart to the old REST `POST /sync/record`. Does NOT touch Cas
  or CasMeta at all — the ledger was already bumped when the blob
  itself was uploaded; writing the same hash's record again must not
  double-count `ref_count`.
  """
  @spec sync_record(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          content_cas :: String.t(),
          file_metadata(),
          opts :: keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def sync_record(%{did: actor_did} = actor, tenant_uuid, content_cas, metadata, opts \\ []) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    row_id = Keyword.get(opts, :file_id) || generate_file_id()

    row = %{
      id: row_id,
      did: owner_did,
      gid: tenant_uuid,
      name: metadata.filename,
      mime_type: metadata[:content_type] || "application/octet-stream",
      size_bytes: metadata[:size_bytes] || 0,
      content_cas: content_cas,
      created_at: System.os_time(:microsecond)
    }

    case PzdbConnector.write(actor, PzdbUri.to_string(uri), [row]) do
      :ok -> {:ok, row_id}
      {:error, _} = err -> err
    end
  end

  @doc "Lists file metadata rows for `owner_did`'s `space` (both default: actor's own, \"private\")."
  @spec list_recent(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), opts :: keyword()) ::
          {:ok, binary()} | {:error, term()}
  def list_recent(%{did: actor_did} = actor, tenant_uuid, opts \\ []) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    PzdbConnector.read_many(actor, PzdbUri.to_string(uri))
  end

  @doc """
  Downloads content bytes for a known content_cas hash belonging to
  `owner_did`'s `space`. Cas.get/3 authorizes actor against that
  specific space before touching S3 — no separate check needed here.
  """
  @spec download(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          owner_did :: String.t(),
          content_cas :: String.t(),
          opts :: keyword()
        ) :: {:ok, binary()} | {:error, term()}
  def download(actor, tenant_uuid, owner_did, content_cas, opts \\ []) do
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    Cas.get(actor, uri, content_cas)
  end

  @doc """
  Presigned, short-lived S3 GET URL for a known content_cas hash
  belonging to `owner_did`'s `space`. Cas.presigned_get_url/4
  authorizes actor against that specific space before generating
  anything — no separate check needed here. GraphQL-native counterpart
  to download/5 above (which streams bytes, for non-GraphQL callers).
  """
  @spec download_url(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          owner_did :: String.t(),
          content_cas :: String.t(),
          opts :: keyword()
        ) :: {:ok, String.t()} | {:error, term()}
  def download_url(actor, tenant_uuid, owner_did, content_cas, opts \\ []) do
    space = Keyword.get(opts, :space, @default_space)
    expires_in = Keyword.get(opts, :expires_in, 300)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    Cas.presigned_get_url(actor, uri, content_cas, expires_in: expires_in)
  end

  defp build_pzdb_uri(tenant_uuid, did, space) do
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, space: space, table: @table}
  end

  defp generate_file_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  # Best-effort — a ledger hiccup should never fail a file upload whose
  # bytes and index row already succeeded (or are about to). Same
  # posture as the old controller's record_cas_meta/5, which rescued
  # around itself for the same reason.
  defp record_cas_meta(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
    case CasMeta.record(actor, tenant_uuid, owner_did, content_cas, size_bytes, space) do
      {:ok, ref_count} ->
        ref_count

      {:error, reason} ->
        Logger.warning(
          "[Przma.Vault.Files] cas_meta record failed did=#{owner_did} hash=#{content_cas} reason=#{inspect(reason)}"
      )

      1
    end
  rescue
    e ->
      Logger.warning("[Przma.Vault.Files] cas_meta record error #{inspect(e)}")
      1
  end

  defp maybe_replicate_to_commons(_owner_did, _created_by, _content_cas, _metadata, _size_bytes, _ref_count, space, _uri)
      when space != "public" do
    :ok
  end

  defp maybe_replicate_to_commons(owner_did, created_by, content_cas, metadata, size_bytes, ref_count, "public", uri) do
    s3_uri = internal_s3_uri_for(uri, content_cas)
    mime_type = metadata[:content_type] || "application/octet-stream"

    Przma.CommonsCas.Replicator.replicate(owner_did, created_by, content_cas, mime_type, size_bytes, ref_count, s3_uri)
  rescue
    e ->
      Logger.warning("[Przma.Vault.Files] commons replication error #{inspect(e)}")
      :ok
  end

# Mirrors Cas's own cas_key/2 shape — duplicated here rather than
# reaching into Cas's private function. If Cas's key format ever
# changes, update this alongside it.
  defp internal_s3_uri_for(%PzdbUri{did: did, namespace: namespace}, digest) do
    shard = String.slice(digest, 0, 2)
    sanitized_did = String.replace(did, [":", " "], "_")
    bucket = Application.get_env(:przma, :vault) |> Keyword.get(:s3_bucket)
    "s3://#{bucket}/#{sanitized_did}/#{namespace}/cas/#{shard}/#{digest}"
  end
end