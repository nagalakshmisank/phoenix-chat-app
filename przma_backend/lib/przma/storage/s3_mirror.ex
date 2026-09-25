defmodule Przma.Storage.S3Mirror do
  @moduledoc """
  Read-only JSON copy of each CouchDB document in Linode S3, placed in
  the SAME namespace/space folders Lance uses — so the metadata can be
  viewed in the S3 console next to the .lance files:

      s3://perkeep/did_przma_kc_user1/vault/private/profile.lance/        (Lance, unchanged)
      s3://perkeep/did_przma_kc_user1/vault/private/profile.couch.json    (this mirror)
                                      └ns─┘ └space┘ └─ table ─┘

  Key rule (built only from the %PzdbUri{}, same sanitising as Lance/Cas):

      single-doc table   {did}/{namespace}/{space}/{table}.couch.json
      record table       {did}/{namespace}/{space}/{table}/{record}.couch.json

  CouchDB is the SOURCE OF TRUTH. Nothing reads profile data from here.
  The file carries CouchDB's `_rev`; if it differs from CouchDB's
  current `_rev`, the mirror is stale.

  Write-through: DocStoreAdapter calls put/3 right after a successful
  CouchDB write. A mirror failure is logged and does NOT fail the
  request (CouchDB already holds the data); the next write refreshes it.

  Disable with S3_MIRROR_ENABLED=false.
  """

  require Logger
  alias Przma.Vault.PzdbUri

  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(Application.get_env(:przma, :s3_mirror, []), :enabled, true)

  @spec key_for(PzdbUri.t(), String.t() | nil) :: String.t()
  def key_for(%PzdbUri{did: did, namespace: ns, space: space, table: table}, nil),
    do: Enum.join([seg(did), ns, space, "#{table}.couch.json"], "/")

  def key_for(%PzdbUri{did: did, namespace: ns, space: space, table: table}, record_id),
    do: Enum.join([seg(did), ns, space, table, "#{record_id}.couch.json"], "/")

  @doc "Writes the document JSON. Always returns :ok (failures are logged)."
  @spec put(PzdbUri.t(), String.t() | nil, map()) :: :ok
  def put(%PzdbUri{} = uri, record_id, %{} = doc) do
    if enabled?() do
      key = key_for(uri, record_id)
      body = Jason.encode!(doc, pretty: true)

      request =
        ExAws.S3.put_object(bucket(), key, body,
          content_type: "application/json",
          meta: [{"couch-rev", to_string(doc["_rev"])}]
        )

      case ExAws.request(request, s3_opts()) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("S3 mirror write failed for #{key}: #{inspect(reason)} (CouchDB is unaffected)")
          :ok
      end
    else
      :ok
    end
  end

  # Same sanitising as PRZMA.PzDb.seg/1 and Cas: did:przma:x -> did_przma_x
  defp seg(s), do: String.replace(s, [":", " "], "_")

  # Same S3 settings Cas uses (config :przma, :vault).
  defp bucket, do: vault(:s3_bucket)

  defp s3_opts do
    [
      access_key_id: vault(:s3_access_key),
      secret_access_key: vault(:s3_secret_key),
      region: vault(:s3_region),
      host: vault(:s3_endpoint) |> String.replace_prefix("https://", "") |> String.replace_prefix("http://", ""),
      scheme: "https://"
    ]
  end

  defp vault(key), do: Application.get_env(:przma, :vault) |> Keyword.fetch!(key)
end
