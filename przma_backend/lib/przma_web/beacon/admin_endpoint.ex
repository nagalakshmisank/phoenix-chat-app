defmodule PRZMAWeb.Beacon.AdminEndpoint do
  @moduledoc """
  Second HTTP endpoint, ONLY for Beacon CMS admin (default port 4300).

  The platform API keeps running on PRZMAWeb.Endpoint (port 4200) with its
  own router — nothing about it changes. This endpoint is started by
  Przma.Beacon.Supervisor only when BEACON_ENABLED=true. Keep port 4300
  closed to the internet (firewall / VPN / nginx with IP allow-list).
  """
  use Phoenix.Endpoint, otp_app: :przma

  @session_options [
    store: :cookie,
    key: "_przma_beacon_admin",
    signing_salt: "przma_beacon_ss",
    same_site: "Lax"
  ]

  # Beacon builds page URLs from the site's "proxy endpoint". This endpoint
  # serves the site directly, so it is its own proxy.
  def proxy_endpoint, do: __MODULE__

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  # Own telemetry prefix, so admin traffic is never counted as platform API traffic.
  plug Plug.Telemetry, event_prefix: [:przma, :beacon_admin, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PRZMAWeb.Beacon.AdminRouter
end
