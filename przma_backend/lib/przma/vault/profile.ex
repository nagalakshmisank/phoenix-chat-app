defmodule Przma.Vault.Profile do
  @moduledoc """
  User profile — namespace "vault", space "private", table "profile".

      pzdb://s3/{tenant_uuid}/{did}/vault/private/profile

  Every call goes through PzdbConnector (parse -> NamespacePolicy ->
  PzdbAuthorization -> BackendRouter). BackendRouter sends vault/profile
  to DocStoreAdapter, which stores:

      CouchDB  przma_did_… / vault:private:profile   (the profile fields)
      S3       did_…/vault/private/profile.couch.json (read-only JSON mirror)

  This replaces profile.lance for NEW writes. Lance code is untouched.

  `id` is set to `did` — one profile per user. `id` and `tier` are
  bookkeeping and are never stored as profile fields.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @namespace "vault"
  @space "private"
  @table "profile"

  @type attrs :: %{optional(atom() | String.t()) => term()}

  @spec create(PzdbConnector.actor(), String.t(), attrs()) :: :ok | {:error, term()}
  def create(%{did: did} = actor, tenant_uuid, attrs) do
    row =
      Map.merge(attrs, %{
        id: did,
        did: did,
        gid: tenant_uuid,
        created_at: System.os_time(:microsecond)
      })

    actor
    |> PzdbConnector.write(uri(tenant_uuid, did), [row])
    # Beacon CMS: record only real successes
    |> beacon_track(did, "profile_created", attrs)
  end

  @doc "Returns the profile content as a JSON binary."
  @spec get(PzdbConnector.actor(), String.t()) :: {:ok, binary()} | {:error, term()}
  def get(%{did: did} = actor, tenant_uuid) do
    PzdbConnector.read(actor, uri(tenant_uuid, did))
  end

  @doc "Field-level update: only the given attrs change, the rest is kept."
  @spec update(PzdbConnector.actor(), String.t(), attrs()) :: :ok | {:error, term()}
  def update(%{did: did} = actor, tenant_uuid, attrs) do
    row =
      Map.merge(attrs, %{
        id: did,
        did: did,
        gid: tenant_uuid,
        updated_at: System.os_time(:microsecond)
      })

    actor
    |> PzdbConnector.upsert(uri(tenant_uuid, did), [row], [:did])
    |> beacon_track(did, "profile_updated", attrs)
  end

  # Passes the write result through unchanged; on :ok tells Beacon CMS which
  # fields changed (field NAMES only — never the values).
  defp beacon_track(:ok, did, event, attrs) do
    Przma.Beacon.track(did, event, %{fields: attrs |> Map.keys() |> Enum.map(&to_string/1)})
    :ok
  end

  defp beacon_track(result, _did, _event, _attrs), do: result

  @spec uri(String.t(), String.t()) :: String.t()
  def uri(tenant_uuid, did) do
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, space: @space, table: @table}
    |> PzdbUri.to_string()
  end
end
