defmodule PRZMAWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :przma
  use Absinthe.Phoenix.Endpoint

  # Websocket for GraphQL subscriptions. Connect with ?token=<Keycloak access token>.
  socket "/socket", PRZMAWeb.UserSocket, websocket: true, longpoll: false

  @session_options [
    store: :cookie,
    key: "_przma_key",
    signing_salt: "przma_salt",
    same_site: "Lax"
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PRZMAWeb.Router
end