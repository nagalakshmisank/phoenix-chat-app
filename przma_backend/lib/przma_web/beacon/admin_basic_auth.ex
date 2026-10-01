defmodule PRZMAWeb.Beacon.AdminBasicAuth do
  @moduledoc """
  Login for the Beacon admin (Beacon ships no login of its own).

  SAMPLE STAGE: HTTP Basic auth, credentials from env vars:

      export BEACON_ADMIN_USERNAME=admin
      export BEACON_ADMIN_PASSWORD='a-long-password'

  If BEACON_ADMIN_PASSWORD is missing, /admin answers 503 — it fails
  closed, never open. Use only over HTTPS / VPN outside localhost.

  NEXT: replace with Keycloak login (realm przma) + `beacon-admin` role.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    username = System.get_env("BEACON_ADMIN_USERNAME", "admin")

    case System.get_env("BEACON_ADMIN_PASSWORD") do
      password when password in [nil, ""] ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Beacon admin is disabled: set BEACON_ADMIN_PASSWORD and restart")
        |> halt()

      password ->
        Plug.BasicAuth.basic_auth(conn, username: username, password: password, realm: "Beacon CMS")
    end
  end
end
