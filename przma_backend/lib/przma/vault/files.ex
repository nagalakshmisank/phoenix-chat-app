defmodule Przma.Vault.Files do
  @moduledoc """
  File upload/download for the "files" namespace, across its 3 spaces:
    - "private" (default) — owner-only by default, but grantable in
      principle once live_grant_for/2 is implemented
    - "public" — shareable
    - "personal" — absolute, never grantable under any circumstance
      (NamespacePolicy.personal_space?/1), same guarantee as vault's
      own personal space

  Two writes per upload, in this ORDER, both gated:
    1. CONTENT — Cas.put/3 authorizes actor against the target space
       BEFORE writing any bytes to S3 — nothing is written unless the
       actor is actually allowed to write into that space.
    2. METADATA — one row via PzdbConnector, which authorizes again
       (same check, cheap, harmless to repeat) before the row lands.

  Content is deduplicated per-DID across all 3 spaces (see Cas
  moduledoc) — the metadata row is what's actually access-controlled
  per space; the physical bytes have no per-space copy at all.
  """

  alias Przma.Vault.{Cas, PzdbAuthorization, PzdbConnector, PzdbUri}

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

  @doc "Lists file metadata rows for `owner_did`'s `space` (both default: actor's own, \"private\")."
  @spec list_recent(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), opts :: keyword()) ::
          {:ok, binary()} | {:error, term()}
  def list_recent(%{did: actor_did} = actor, tenant_uuid, opts \\ []) do
    owner_did = Keyword.get(opts, :owner_did, actor_did)
    space = Keyword.get(opts, :space, @default_space)
    uri = build_pzdb_uri(tenant_uuid, owner_did, space)
    PzdbConnector.read(actor, PzdbUri.to_string(uri))
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

  defp build_pzdb_uri(tenant_uuid, did, space) do
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, space: space, table: @table}
  end

  defp generate_file_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end