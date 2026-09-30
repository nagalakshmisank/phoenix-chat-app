defmodule Przma.Vault.CasMeta do
  @moduledoc """
  Per-user CAS (content-addressed storage) ledger — one CouchDB document
  per unique file hash, in the internal "cas" folder of the files service:

      pzdb://s3/{tenant}/{did}/files/cas/cas_meta
        -> CouchDB  przma_{did} / files:cas:cas_meta:{sha256}

  The bytes themselves are NOT here: Cas.put/3 stores them once per hash
  in S3 at {did}/files/cas/{shard}/{sha256}. This document describes that
  object: size, S3 location, how many file records point at it
  (ref_count) and which spaces referenced it (referenced_spaces).

  Keyed by hash only, NOT by space: the same bytes uploaded into
  "private" and later "public" are one S3 object and one ledger document
  with ref_count 2 and referenced_spaces ["private", "public"].

  ref_count is incremented ATOMICALLY: the row carries
  "$inc" => %{"ref_count" => 1}, which DocStoreAdapter applies to the
  current document under its _rev and retries on a CouchDB conflict —
  two simultaneous uploads of the same file both count.

  "cas" is owner-only (NamespacePolicy.internal_space?/1): no other user
  can read or write someone's ledger.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @namespace "files"
  @ledger_space "cas"
  @table "cas_meta"

  @doc """
  Records that `digest` was just written (or re-referenced) from `space`
  under `owner_did`. Returns the new ref_count.
  """
  @spec record(
          actor :: PzdbConnector.actor(),
          tenant_uuid :: String.t(),
          owner_did :: String.t(),
          digest :: String.t(),
          size_bytes :: integer(),
          space :: String.t()
        ) :: {:ok, non_neg_integer()} | {:error, term()}
  def record(actor, tenant_uuid, owner_did, digest, size_bytes, space) do
    uri_string = build_uri(tenant_uuid, owner_did)

    row = %{
      "id" => digest,
      "hash" => digest,
      "hash_alg" => "sha256",
      "cas_uri" => "cas:sha256:#{digest}",
      "uri" => shareable_uri(digest, owner_did),
      "uri_type" => "graphql",
      "s3_key" => s3_key(owner_did, digest),
      "s3_uri" => internal_s3_uri(owner_did, digest),
      "size_bytes" => size_bytes,
      "last_space" => space,
      "$inc" => %{"ref_count" => 1},
      "$add_to_set" => %{"referenced_spaces" => space}
    }

    with :ok <- PzdbConnector.write(actor, uri_string, [row]),
         {:ok, doc} <- get(actor, tenant_uuid, owner_did, digest) do
      {:ok, doc["ref_count"] || 1}
    end
  end

  @doc "One ledger document by hash (a map), or {:error, :not_found}."
  @spec get(PzdbConnector.actor(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(actor, tenant_uuid, owner_did, digest) do
    with {:ok, raw} <- PzdbConnector.read_by_id(actor, build_uri(tenant_uuid, owner_did), digest),
         {:ok, %{} = doc} <- Jason.decode(raw) do
      {:ok, doc}
    else
      {:ok, _other} -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc "Every ledger document (one per unique blob) for `owner_did`."
  @spec list(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), owner_did :: String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def list(actor, tenant_uuid, owner_did) do
    case PzdbConnector.read_many(actor, build_uri(tenant_uuid, owner_did)) do
      {:ok, raw} -> {:ok, decode_rows(raw)}
      {:error, _} = err -> err
    end
  end

  @doc "Internal S3 URI of the blob — the value replicated to Postgres for public files."
  @spec internal_s3_uri(String.t(), String.t()) :: String.t()
  def internal_s3_uri(did, digest) do
    endpoint = vault_config(:s3_endpoint) || ""
    "#{endpoint}/#{vault_config(:s3_bucket)}/#{s3_key(did, digest)}"
  end

  # -- private -------------------------------------------------------

  defp build_uri(tenant_uuid, did) do
    %PzdbUri{
      transport: :s3,
      tenant_id: tenant_uuid,
      did: did,
      namespace: @namespace,
      space: @ledger_space,
      table: @table
    }
    |> PzdbUri.to_string()
  end

  # Client-facing reference — routed through the GraphQL blobDownloadUrl
  # query (see FilesResolver), which re-authorizes before ever touching
  # S3. Never the s3_uri below.
  defp shareable_uri(digest, owner_did) do
    "/api/graphql#blobDownloadUrl(hash:\"#{digest}\",owner:\"#{owner_did}\")"
  end

  # Same key shape Cas.put/3 writes: {sanitized_did}/files/cas/{shard}/{hash}
  defp s3_key(did, digest) do
    "#{String.replace(did, [":", " "], "_")}/#{@namespace}/cas/#{String.slice(digest, 0, 2)}/#{digest}"
  end

  defp vault_config(key), do: Application.get_env(:przma, :vault) |> Keyword.get(key)

  defp decode_rows(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_list(decoded) -> decoded
      {:ok, decoded} when is_map(decoded) -> [decoded]
      _ -> []
    end
  end
end
