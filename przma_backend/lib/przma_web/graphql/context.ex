defmodule PRZMAWeb.Graphql.Context do
  @moduledoc """
  Copies the verified Keycloak identity from conn.assigns (set by
  KeycloakAuth) into the Absinthe context. Uses conn.assigns[...] rather
  than conn.assigns.x so the unauthenticated GraphiQL page (GET) does not
  crash with a KeyError; resolvers reject a nil did.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    context = %{
      did: conn.assigns[:did],
      tenant_uuid: conn.assigns[:tenant_uuid],
      storage_tier: conn.assigns[:storage_tier] || 1,
      token_claims: conn.assigns[:token_claims] || %{},
      roles: conn.assigns[:roles] || []
    }

    Absinthe.Plug.put_options(conn, context: context)
  end
end
