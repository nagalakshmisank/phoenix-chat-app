defmodule PRZMAWeb.Router do
  use PRZMAWeb, :router

  # ------------------------------------------------------------
  # GraphQL Context
  # ------------------------------------------------------------
  pipeline :graphql_context do
    plug PRZMAWeb.Graphql.Context
  end

  # ------------------------------------------------------------
  # GraphiQL Page Authentication
  # ------------------------------------------------------------
  pipeline :graphiql_page_auth do
    plug PRZMAWeb.Plugs.GraphiqlPageAuth
  end

  # ------------------------------------------------------------
  # API
  # ------------------------------------------------------------
  pipeline :api do
    plug :accepts, ["json"]
  end

  # ------------------------------------------------------------
  # Keycloak Authentication
  # ------------------------------------------------------------
  pipeline :require_did_auth do
    plug PRZMAWeb.Plugs.KeycloakAuth
  end

  # ------------------------------------------------------------
  # Authorisation scope for REST routes (GraphQL fields are checked
  # by PRZMAWeb.Graphql.Middleware.Authz instead)
  # ------------------------------------------------------------
  pipeline :authorize do
    plug PRZMAWeb.Plugs.Authorize
  end

  # ------------------------------------------------------------
  # OpenAPI
  # ------------------------------------------------------------
  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec,
      module: PRZMAWeb.ApiSpec
  end

  # ------------------------------------------------------------
  # OpenAPI JSON
  # ------------------------------------------------------------
  scope "/api/openapi" do
    pipe_through :openapi

    get "/",
      OpenApiSpex.Plug.RenderSpec,
      []
  end

  # ------------------------------------------------------------
  # Swagger UI
  # ------------------------------------------------------------
  scope "/swaggerui" do
    pipe_through :openapi

    get "/",
      OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi"
  end

  # ------------------------------------------------------------
  # REST API v1
  # ------------------------------------------------------------
  scope "/api/v1", PRZMAWeb do
    pipe_through [
      :api,
      :require_did_auth,
      :authorize
    ]

    # Registration
    post "/registration/complete",
         RegistrationController,
         :complete

    # Profile
    post "/profile",
         ProfileController,
         :create

    get "/profile",
        ProfileController,
        :show

    patch "/profile",
          ProfileController,
          :update

    # Vector / keyword search over the logged-in user's own content
    get "/search",
        SearchController,
        :search

    post "/search/index",
         SearchController,
         :index

    get "/search/stats",
        SearchController,
        :stats
  end

  # ------------------------------------------------------------
  # GraphQL / GraphiQL
  # ------------------------------------------------------------
  #
  # Request flow:
  #
  # Client
  #   ↓
  # :api
  #   ↓
  # :graphiql_page_auth
  #   ↓
  # :require_did_auth
  #   ↓
  # KeycloakAuth
  #   ↓
  # conn.assigns.did / tenant_uuid / auth_method / sid
  #   ↓
  # :graphql_context  (roles from przma_authz tables)
  #   ↓
  # Absinthe context
  #   ↓
  # Middleware.Authz  (scope, feature, session, rate limit)
  #   ↓
  # GraphQL Resolver
  #
  # ------------------------------------------------------------

  scope "/api/graphql" do
    pipe_through [:api, :require_did_auth, :graphql_context]
    forward "/", Absinthe.Plug, schema: PRZMAWeb.Graphql.Schema
  end

  scope "/graphiql" do
    pipe_through [
      :api,
      :graphiql_page_auth,
      :graphql_context
    ]

    forward "/",
      Absinthe.Plug.GraphiQL,
      schema: PRZMAWeb.Graphql.Schema,
      interface: :playground
  end
end
