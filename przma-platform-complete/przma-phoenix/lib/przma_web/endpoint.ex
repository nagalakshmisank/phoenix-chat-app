defmodule PRZMAWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :przma

  @session_options [
    store: :cookie,
    key: "_przma_key",
    signing_salt: "abcdefghijklmnopqrstuvwxyz123456",
  ]

  # Minimal plugs for file sync API
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    # Allow large file uploads (blobs can be many MB). Default is 8MB.
    length: 1_000_000_000,
    read_length: 1_000_000,
    json_decoder: Jason

  plug Plug.Session, @session_options
  plug PRZMAWeb.Router
end
