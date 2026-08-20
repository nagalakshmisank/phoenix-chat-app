defmodule PRZMAWeb.RegistrationController do
  use PRZMAWeb, :controller
  alias Przma.Vault.SpaceProvisioner

  @doc """
  Called once, right after Keycloak registration completes and the
  frontend has an access token — NOT on every login. Provisions all 4
  spaces (vault/public/circle/professional) and writes the profile row
  into the vault (private) space in the same call.
  """
  def complete(conn, params) do
    actor = %{did: conn.assigns.did, origin_instance_id: nil, portable_grant: nil}
    tenant_uuid = conn.assigns.tenant_uuid

    profile_attrs = %{
      email: conn.assigns.token_claims["email"],
      nickname: Map.get(params, "nickname", conn.assigns.token_claims["preferred_username"])
    }

    case SpaceProvisioner.provision_all(actor, tenant_uuid, profile_attrs) do
      :ok -> json(conn, %{status: "registered", did: actor.did, gid: tenant_uuid})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
end
