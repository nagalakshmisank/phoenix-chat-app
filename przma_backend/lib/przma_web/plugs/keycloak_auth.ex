defmodule PRZMAWeb.Plugs.KeycloakAuth do
  @moduledoc """
  Verifies the bearer JWT locally via JWKS (Przma.Auth.JwksCache)
  rather than calling Keycloak's /userinfo on every request. Sets
  conn.assigns[:did], [:tenant_uuid], [:storage_tier], [:token_claims]
  — everything downstream (Profile, SpaceProvisioner, controllers)
  reads from these, never from the request body.
  """
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- verify(token) do
      did = "did:przma:#{claims["preferred_username"]}"

      conn
      |> assign(:did, did)
      |> assign(:tenant_uuid, claims["sub"])
      |> assign(:storage_tier, extract_tier(claims))
      |> assign(:token_claims, claims)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end

  defp verify(token) do
    with {:ok, jwk} <- Przma.Auth.JwksCache.current_jwk(),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
      if claims["exp"] > System.system_time(:second) do
        {:ok, claims}
      else
        {:error, :expired}
      end
    else
      _ ->
        # Signature check failed — could be genuinely invalid, or the
        # realm key rotated since boot. Refresh once and retry before
        # giving up.
        Przma.Auth.JwksCache.refresh()

        with {:ok, jwk} <- Przma.Auth.JwksCache.current_jwk(),
             {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token),
             true <- claims["exp"] > System.system_time(:second) do
          {:ok, claims}
        else
          _ -> {:error, :invalid_token}
        end
    end
  end

  defp extract_tier(claims) do
    roles = get_in(claims, ["realm_access", "roles"]) || []

    cond do
      "tier3-user" in roles -> 3
      "tier2-user" in roles -> 2
      true -> 1
    end
  end
end
