defmodule PRZMAWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :przma

  @session_options [
    store: :cookie,
    key: "_przma_key",
    signing_salt: "przma_salt",
    same_site: "Lax"
  ]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PRZMAWeb.Router
end
