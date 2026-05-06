defmodule ChatApiWeb.Router do
  use ChatApiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  # ── API v1 Chat Routes ──────────────────────────────────────
  scope "/api/v1/chat", ChatApiWeb do
    pipe_through :api

    # Token
    post   "/socket/token",          TokenController,   :create

    # Session
    post   "/session/join",          SessionController, :join
    get    "/session/me",            SessionController, :me

    # Rooms
    get    "/rooms",                 RoomController,    :index
    post   "/rooms",                 RoomController,    :create
    get    "/rooms/:id",             RoomController,    :show
    get    "/rooms/:id/members",     RoomController,    :members
    get    "/rooms/:id/status",      RoomController,    :status
    post   "/rooms/:id/join",        RoomController,    :join
    delete "/rooms/:id/leave",       RoomController,    :leave

    # Messages
    get    "/rooms/:id/messages",    MessageController, :index
    post   "/rooms/:id/messages",    MessageController, :send_message
    post   "/messages/private",      MessageController, :send_private

    # Typing
    post   "/rooms/:id/typing",      TypingController,  :notify
  end

  # ── Swagger Spec ────────────────────────────────────────────
  scope "/api" do
    pipe_through :api
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end

  # ── Swagger UI ──────────────────────────────────────────────
  scope "/" do
    pipe_through :browser
    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi"
  end
end
