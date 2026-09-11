defmodule Przma.Vault.Profile do
  @moduledoc """
  User profile — one row, its own Lance table, in the "private" space
  of the "vault" namespace. "vault" is now an ordinary namespace like
  any other (ceiling: [:read, :write], vault_scope: :private) — the
  absolute owner-only guarantee comes from the SPACE ("private" here),
  not from the namespace name. If profile should be truly ungrantable
  rather than merely private-by-default, use space: "personal" instead
  (see NamespacePolicy.personal_space?/1) — "private" is grantable in
  principle, once live_grant_for/2 is implemented.

  Physical path via PRZMA.PzDb: pzdb://{did}/vault/private/profile —
  see lance_linode_adapter.ex for the real S3 shape.

  `id` is set equal to `did` — the real pzdb_upsert NIF deletes by
  `id` before inserting (its upsert strategy), so every table's rows
  need an `id`; for a one-row-per-user table like this, `did` IS the
  natural id.
  """

  alias Przma.Vault.{PzdbConnector, PzdbUri}

  @namespace "vault"
  @space "private"
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
    %PzdbUri{transport: :s3, tenant_id: tenant_uuid, did: did, namespace: @namespace, space: @space, table: @table}
    |> PzdbUri.to_string()
  end
end