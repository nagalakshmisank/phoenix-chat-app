defmodule Przma.Vault.Cas do
  @moduledoc """
  Content-addressed blob storage — generic across any namespace, not
  hardcoded to "files". Sits directly under {did}/{namespace}/, a
  sibling of whatever spaces that namespace has (private/public/
  personal), never nested inside any one of them — so identical
  content referenced from two different spaces is stored once, not
  duplicated.

  AUTHORIZATION IS ENFORCED HERE, not left to the caller: put/3 and
  get/3 take the actor and a real %PzdbUri{} and run the exact same
  PzdbAuthorization.authorize/3 chain every other namespace goes
  through, BEFORE touching S3. The URI's `space` field decides which
  space's rules gate this specific access (so uploading into "public"
  is checked against "public"'s rules, even though the resulting bytes
  land in the same DID-level CAS store as "private" uploads would) —
  but the physical S3 key deliberately ignores `space` entirely and
  uses only `did` + `namespace`, since storage location and
  authorization are two different axes here.

  NOT via the pzdb NIF (PRZMA.PzDb only upserts/queries structured
  Lance records; it has no raw-bytes path) — this is a direct S3 PUT/
  GET using the previously-unused :vault config block in runtime.exs.

  HASH ALGORITHM: SHA-256 via :crypto (zero new native deps), not
  BLAKE3 — flagged for supervisor sign-off since the schema field is
  named content_cas/blake3_cid; swap hash/1 if BLAKE3 is required.
  """

  alias Przma.Vault.{PzdbAuthorization, PzdbUri}

  @doc "SHA-256 hex digest of file bytes — this becomes the CAS key."
  @spec hash(binary()) :: String.t()
  def hash(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  Authorizes actor against `uri` for :write, THEN uploads bytes to
  {did}/{namespace}/cas/{shard}/{hash}. `uri.space` decides which
  space's rules gate this write; the resulting key never includes
  `space` at all.
  """
  @spec put(actor :: map(), uri :: PzdbUri.t(), bytes :: binary()) ::
          {:ok, String.t()} | {:error, term()}
  def put(actor, %PzdbUri{} = uri, bytes) when is_binary(bytes) do
    with :ok <- PzdbAuthorization.authorize(actor, uri, :write) do
      digest = hash(bytes)
      key = cas_key(uri, digest)

      case ExAws.S3.put_object(bucket(), key, bytes) |> ExAws.request(s3_opts()) do
        {:ok, _} -> {:ok, digest}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Authorizes actor against `uri` for :read, THEN fetches bytes for a known content hash."
  @spec get(actor :: map(), uri :: PzdbUri.t(), digest :: String.t()) ::
          {:ok, binary()} | {:error, term()}
  def get(actor, %PzdbUri{} = uri, digest) do
    with :ok <- PzdbAuthorization.authorize(actor, uri, :read) do
      case ExAws.S3.get_object(bucket(), cas_key(uri, digest)) |> ExAws.request(s3_opts()) do
        {:ok, %{body: body}} -> {:ok, body}
        {:error, {:http_error, 404, _}} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # {did}/{namespace}/cas/{shard}/{hash} — namespace comes from the
  # URI (whatever it is: "files", or any future namespace with its
  # own CAS needs), never hardcoded. `space` is intentionally NOT part
  # of this key — see moduledoc.
  defp cas_key(%PzdbUri{did: did, namespace: namespace}, digest) do
    shard = String.slice(digest, 0, 2)
    "#{sanitize(did)}/#{namespace}/cas/#{shard}/#{digest}"
  end

  defp sanitize(did), do: String.replace(did, [":", " "], "_")

  defp bucket, do: vault_config(:s3_bucket)

  defp s3_opts do
    [
      access_key_id: vault_config(:s3_access_key),
      secret_access_key: vault_config(:s3_secret_key),
      region: vault_config(:s3_region),
      host: s3_host(),
      scheme: "https://"
    ]
  end

  defp s3_host do
    vault_config(:s3_endpoint)
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
  end

  defp vault_config(key), do: Application.get_env(:przma, :vault) |> Keyword.fetch!(key)
end