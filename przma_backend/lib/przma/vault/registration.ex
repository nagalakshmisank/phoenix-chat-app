defmodule Przma.Vault.Registration do
  @moduledoc """
  Registration completion, shared by the REST controller and GraphQL
  resolver so both follow exactly the same path.

  Identity comes ONLY from the verified Keycloak token (set by
  KeycloakAuth) — never from request parameters. The only client input
  is the optional nickname.
  """

  alias Przma.Storage.CouchDbName
  alias Przma.Vault.SpaceProvisioner

  @type identity :: %{
          did: String.t(),
          tenant_uuid: String.t(),
          storage_tier: 1..3,
          token_claims: map()
        }

  @spec complete(identity(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def complete(%{did: did, tenant_uuid: tenant_uuid} = identity, nickname \\ nil) do
    claims = identity[:token_claims] || %{}
    actor = %{did: did, origin_instance_id: nil, portable_grant: nil}

    attrs =
      %{email: claims["email"], nickname: blank_to_nil(nickname) || claims["preferred_username"]}
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case SpaceProvisioner.provision_all(actor, tenant_uuid, attrs, tier: identity[:storage_tier] || 1) do
      :ok ->
        {:ok, %{status: "registered", did: did, gid: tenant_uuid, database: CouchDbName.from_did(did)}}

      {:error, _} = err ->
        err
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: String.trim(s))
end
