defmodule Przma.Storage.Location do
  @moduledoc """
  Where one user's data lives (tier1 / tier2), from the central table
  `przma_authz.storage_locations`.

      tier 1  bucket perkeep (shared)        base s3://perkeep
      tier 2  bucket przma-<keycloak uuid>   base s3://przma-<keycloak uuid>

  Inside the bucket the layout is unchanged:
      {base}/did_przma_<user>/<service>/<space>/<table>.lance
      {bucket}/did_przma_<user>/<namespace>/cas/<shard>/<hash>

  Both tiers use the same Linode endpoint, region and access keys
  (AWS_* env), so the Rust NIF needs no change. Tier 3 (user's own S3)
  is not supported yet.

  base_for/1 is called by PRZMA.PzDb and LanceDocPath for every table
  path, and bucket_for/1 by Przma.Vault.Cas, so it is cached (60 s). If
  Postgres is unreachable the last known value is used; a user with no
  row (system DIDs, or a user who has not registered since this was
  deployed) uses the default base path (VAULT_BASE_PATH).
  """

  require Logger
  alias Przma.Authz.{Cache, Db, Telemetry}

  @doc "Base path for a DID, e.g. \"s3://perkeep\" or \"s3://przma-18dd…\"."
  @spec base_for(String.t()) :: String.t()
  def base_for("did:przma-system" <> _), do: default_base()

  def base_for(did) when is_binary(did) do
    case location(did) do
      %{base_path: base} when is_binary(base) -> base
      _ -> default_base()
    end
  end

  def base_for(_), do: default_base()

  @doc "S3 bucket for a DID (for the CAS blobs)."
  @spec bucket_for(String.t()) :: String.t()
  def bucket_for("did:przma-system" <> _), do: default_bucket()

  def bucket_for(did) when is_binary(did) do
    case location(did) do
      %{bucket: bucket} when is_binary(bucket) -> bucket
      _ -> default_bucket()
    end
  end

  def bucket_for(_), do: default_bucket()

  @doc "The storage_locations row (cached), or nil."
  def location(did) do
    case Cache.get({:location, did}) do
      {:ok, row} ->
        row

      :miss ->
        case Db.one(
               "SELECT storage_tier, bucket, base_path, status FROM przma_authz.storage_locations WHERE did = $1",
               [did]
             ) do
          {:ok, row} ->
            Cache.put({:location, did}, row)

          {:error, reason} ->
            case Cache.get_stale({:location, did}) do
              {:ok, row} ->
                row

              :miss ->
                Logger.error("Storage.Location: no location for #{did} (#{inspect(reason)}), using default base")
                nil
            end
        end
    end
  end

  @doc "Row values for a new user of `tier` (1 or 2)."
  def plan_for(1, _keycloak_uuid), do: %{tier: 1, bucket: default_bucket(), base_path: default_base(), status: "ready"}

  def plan_for(2, keycloak_uuid) do
    bucket = tier2_bucket(keycloak_uuid)
    %{tier: 2, bucket: bucket, base_path: "s3://" <> bucket, status: "provisioning"}
  end

  def tier2_bucket(keycloak_uuid), do: "przma-" <> String.downcase(keycloak_uuid)

  @doc """
  Creates a tier2 bucket and marks the row ready. Safe to repeat
  (a bucket we already own counts as success).
  """
  def provision(did) do
    with %{bucket: bucket, status: status} when status in ["provisioning", "failed"] <- fresh(did) do
      case create_bucket(bucket) do
        :ok ->
          set_status(did, "ready")

        {:error, reason} ->
          set_status(did, "failed")
          Logger.error("Storage.Location: bucket #{bucket} for #{did} failed: #{inspect(reason)}")
          {:error, {:storage_provisioning_failed, reason}}
      end
    else
      %{status: "ready"} -> :ok
      %{status: "migrating"} -> :ok
      nil -> {:error, :no_storage_location}
      {:error, _} = err -> err
    end
  end

  @doc "True when the user already has objects under their folder in `bucket`."
  def has_data?(bucket, did) do
    case ExAws.S3.list_objects_v2(bucket, prefix: folder(did) <> "/", max_keys: 1) |> ExAws.request(s3_opts()) do
      {:ok, %{body: %{contents: [_ | _]}}} -> true
      {:ok, _} -> false
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Copies a user's whole folder to a new bucket and switches their
  location to it (tier1 -> tier2, or a legacy tier2 user whose data is
  still in perkeep). While it runs the row is `migrating` and the guard
  refuses that user's calls with `storage_migrating`, so nothing is
  written half-way. Old objects are NOT deleted — clean them up by hand
  after checking the new bucket.
  """
  def migrate(did, to_tier, keycloak_uuid, actor \\ "system") do
    with %{bucket: from_bucket} = before <- fresh(did) || {:error, :no_storage_location},
         target = plan_for(to_tier, keycloak_uuid),
         true <- target.bucket != from_bucket || {:error, :already_there},
         :ok <- set_status(did, "migrating"),
         :ok <- (to_tier == 1 && :ok) || create_bucket(target.bucket),
         {:ok, copied} <- copy_folder(did, from_bucket, target.bucket) do
      :ok =
        Db.exec(
          """
          UPDATE przma_authz.storage_locations
             SET storage_tier = $2, bucket = $3, base_path = $4, status = 'ready', updated_at = now()
           WHERE did = $1
          """,
          [did, target.tier, target.bucket, target.base_path]
        )

      Cache.invalidate(did)

      Telemetry.audit(%{
        actor: actor,
        action: "storage.migrated",
        target_type: "account",
        target_id: did,
        before: Map.take(before, [:storage_tier, :bucket, :base_path]),
        after: %{storage_tier: target.tier, bucket: target.bucket, base_path: target.base_path, objects_copied: copied}
      })

      {:ok, %{objects_copied: copied, bucket: target.bucket}}
    else
      {:error, :already_there} ->
        {:ok, %{objects_copied: 0}}

      {:error, reason} = err ->
        set_status(did, "ready")
        Logger.error("Storage.Location: migrate #{did} failed: #{inspect(reason)}")
        err
    end
  end

  # ── S3 ────────────────────────────────────────────────────────────────

  def create_bucket(bucket) do
    case ExAws.S3.put_bucket(bucket, region()) |> ExAws.request(s3_opts()) do
      {:ok, _} -> :ok
      {:error, {:http_error, 409, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_folder(did, from, to) do
    prefix = folder(did) <> "/"

    try do
      count =
        ExAws.S3.list_objects_v2(from, prefix: prefix)
        |> ExAws.stream!(s3_opts())
        |> Enum.reduce(0, fn %{key: key}, n ->
          {:ok, _} = ExAws.S3.put_object_copy(to, key, from, key) |> ExAws.request(s3_opts())
          n + 1
        end)

      {:ok, count}
    rescue
      e -> {:error, e}
    end
  end

  def s3_opts do
    [
      access_key_id: vault(:s3_access_key),
      secret_access_key: vault(:s3_secret_key),
      region: region(),
      host: vault(:s3_endpoint) |> String.replace_prefix("https://", "") |> String.replace_prefix("http://", ""),
      scheme: "https://"
    ]
  end

  # ── helpers ───────────────────────────────────────────────────────────

  def default_base, do: Application.get_env(:przma, :vault_base_path, "/var/przma/vaults")
  def default_bucket, do: vault(:s3_bucket)

  defp region, do: vault(:s3_region)
  defp vault(key), do: Application.get_env(:przma, :vault, []) |> Keyword.get(key)

  defp folder(did), do: String.replace(did, [":", " "], "_")

  defp fresh(did) do
    Cache.delete({:location, did})

    case Db.one(
           "SELECT storage_tier, bucket, base_path, status FROM przma_authz.storage_locations WHERE did = $1",
           [did]
         ) do
      {:ok, row} -> row
      {:error, _} = err -> err
    end
  end

  defp set_status(did, status) do
    result =
      Db.exec(
        "UPDATE przma_authz.storage_locations SET status = $2, updated_at = now() WHERE did = $1",
        [did, status]
      )

    Cache.invalidate(did)
    result
  end
end
