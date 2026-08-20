defmodule Przma.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Przma.PubSub},
      PRZMAWeb.Endpoint,
      # JWKS cache for KeycloakAuth — fetches Keycloak's signing key
      # once at boot, caches it, refetches on a verify failure (key
      # rotation). See lib/przma/auth/jwks_cache.ex.
      Przma.Auth.JwksCache
    ]

    opts = [strategy: :one_for_one, name: Przma.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PRZMAWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
