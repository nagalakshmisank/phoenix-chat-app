defmodule PRZMAWeb.Router do
  use PRZMAWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_did_auth do
    plug PRZMAWeb.Plugs.KeycloakAuth
  end

  # Same pattern as the real project's router.ex — PutApiSpec loads
  # PRZMAWeb.ApiSpec, then /api/openapi renders it as JSON and
  # /swaggerui renders the interactive page against that JSON.
  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: PRZMAWeb.ApiSpec
  end

  scope "/api/openapi" do
    pipe_through :openapi
    get "/", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/swaggerui" do
    pipe_through :openapi
    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi"
  end

  scope "/api/v1", PRZMAWeb do
    pipe_through [:api, :require_did_auth]

    post "/registration/complete", RegistrationController, :complete

    post "/profile", ProfileController, :create
    get "/profile", ProfileController, :show
    patch "/profile", ProfileController, :update
  end
end
