defmodule PRZMAWeb.Graphql.Context do
  @moduledoc """
  Copies the verified identity from conn.assigns (set by KeycloakAuth)
  into the Absinthe context. Uses conn.assigns[...] rather than
  conn.assigns.x so the unauthenticated GraphiQL page (GET) does not
  crash with a KeyError; resolvers reject a nil did.

  `roles` now comes from the central tables (Przma.Authz.Profile,
  cached 60 s); the authorisation middleware reads auth_method, sid,
  access_key, client_ip and user_agent.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    did = conn.assigns[:did]

    context = %{
      did: did,
      tenant_uuid: conn.assigns[:tenant_uuid],
      storage_tier: conn.assigns[:storage_tier] || 1,
      token_claims: conn.assigns[:token_claims] || %{},
      roles: roles(did),
      auth_method: conn.assigns[:auth_method],
      sid: conn.assigns[:sid],
      access_key: conn.assigns[:access_key],
      client_ip: conn.assigns[:client_ip],
      user_agent: conn.assigns[:user_agent]
    }

    Absinthe.Plug.put_options(conn, context: context)
  end

  defp roles(did) when is_binary(did) do
    case Przma.Authz.profile(did) do
      {:ok, %{roles: roles}} -> roles
      _ -> []
    end
  end

  defp roles(_), do: []
end
