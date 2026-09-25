defmodule PRZMAWeb.RegistrationController do
  use PRZMAWeb, :controller
  alias Przma.Vault.Registration

  @doc """
  REST twin of the GraphQL `completeRegistration` mutation. Call once
  right after Keycloak registration (re-running is safe). Identity comes
  from the verified token only.
  """
  def complete(conn, params) do
    identity = %{
      did: conn.assigns.did,
      tenant_uuid: conn.assigns.tenant_uuid,
      storage_tier: conn.assigns[:storage_tier] || 1,
      token_claims: conn.assigns[:token_claims] || %{}
    }

    case Registration.complete(identity, params["nickname"]) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
end
