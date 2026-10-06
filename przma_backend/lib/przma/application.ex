defmodule Przma.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Small in-memory cache for the social services (account directory
    # lookups). Owned by the application process, so it lives as long as
    # the app does.
    Przma.Social.Cache.init()

    children = [
      {Phoenix.PubSub, name: Przma.PubSub},
      PRZMAWeb.Endpoint,
      # GraphQL subscriptions (notificationReceived, circleEvent).
      {Absinthe.Subscription, PRZMAWeb.Endpoint},
      # JWKS cache for KeycloakAuth — fetches Keycloak's signing key
      # once at boot, caches it, refetches on a verify failure (key
      # rotation). See lib/przma/auth/jwks_cache.ex.
      Przma.Auth.JwksCache,
      Przma.CommonsCas.Repo
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
