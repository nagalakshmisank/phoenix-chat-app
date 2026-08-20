defmodule Przma.Vault.Profile do
  @moduledoc """
  User profile — one row, its own Lance table, inside the PRIVATE
  space. Private space == the "vault" namespace (hard-coded personal
  in NamespacePolicy, never grantable) — profile is a TABLE inside it.

  Physical path now goes through the REAL przma_pzdb_nif (found in the
  mentor's phoenix-chat-app-circle repo), via PzdbConnector ->
  LanceLinodeAdapter -> PRZMA.PzDb. That real system's URI shape is
  pzdb://{did}/{service}/{space}/{table} — NO tenant_uuid segment.
  See lance_linode_adapter.ex's moduledoc for the tenant_uuid-drop and
  space="core" default decisions this depends on.

  `id` is set equal to `did` — the real pzdb_upsert NIF deletes by
  `id` before inserting (its upsert strategy), so every table's rows
  need an `id`; for a one-row-per-user table like this, `did` IS the
  natural id.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @namespace "vault"
  @table "profile"

  @type attrs :: %{
          optional(:gid) => String.t(),
          optional(:email) => String.t(),
          optional(:nickname) => String.t()
        }

  @spec create(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), attrs()) ::
          :ok | {:error, term()}
  def create(%{did: did} = actor, tenant_uuid, attrs) do
    row =
      Map.merge(attrs, %{
        id: did,
        did: did,
        gid: tenant_uuid,
        created_at: System.os_time(:microsecond)
      })

    PzdbConnector.write(actor, build_uri(tenant_uuid, did), [row])
  end

  @spec get(actor :: PzdbConnector.actor(), tenant_uuid :: String.t()) ::
          {:ok, binary()} | {:error, term()}
  def get(%{did: did} = actor, tenant_uuid) do
    PzdbConnector.read(actor, build_uri(tenant_uuid, did))
  end

  @spec update(actor :: PzdbConnector.actor(), tenant_uuid :: String.t(), attrs()) ::
          :ok | {:error, term()}
  def update(%{did: did} = actor, tenant_uuid, attrs) do
    row =
      Map.merge(attrs, %{
        id: did,
        did: did,
        gid: tenant_uuid,
        updated_at: System.os_time(:microsecond)
      })

    # Real pzdb_upsert (delete-by-id then add) genuinely overwrites —
    # unlike the earlier ExAws placeholder, this is a real upsert now.
    PzdbConnector.upsert(actor, build_uri(tenant_uuid, did), [row], [:did])
  end

  defp build_uri(tenant_uuid, did) do
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, table: @table}
    |> PzdbUri.to_string()
  end
end
