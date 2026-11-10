defmodule PRZMAWeb.Plugs.Authorize do
  @moduledoc """
  The REST twin of the GraphQL Authz middleware, for /api/v1 routes.
  Runs after KeycloakAuth. The endpoint name is the HTTP method plus the
  router's path pattern, e.g. "GET /api/v1/profile", looked up in
  przma_authz.api_endpoints.

  Refused calls get the matching HTTP status (401 / 403 / 413 / 429 / 503)
  and a JSON body: {"error": "scope_denied", "needed": "…", "hint": "…"}.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(conn, _opts) do
    req = %{
      did: conn.assigns[:did],
      kind: "rest",
      endpoint: endpoint_name(conn),
      method: conn.assigns[:auth_method] || :jwt,
      key: conn.assigns[:access_key],
      sid: conn.assigns[:sid],
      claims: conn.assigns[:token_claims] || %{},
      ip: conn.assigns[:client_ip],
      user_agent: conn.assigns[:user_agent]
    }

    case Przma.Authz.authorize(req) do
      :ok ->
        conn

      {:error, code, details} ->
        body =
          details
          |> Map.take([:needed, :plan, :limit_per_min])
          |> Map.put(:error, Atom.to_string(code))
          |> then(fn b -> if h = Przma.Authz.hint(code), do: Map.put(b, :hint, h), else: b end)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(Przma.Authz.http_status(code), Jason.encode!(body))
        |> halt()
    end
  end

  defp endpoint_name(conn) do
    route =
      case Phoenix.Router.route_info(PRZMAWeb.Router, conn.method, conn.request_path, conn.host) do
        %{route: route} -> route
        _ -> conn.request_path
      end

    "#{conn.method} #{route}"
  end
end
