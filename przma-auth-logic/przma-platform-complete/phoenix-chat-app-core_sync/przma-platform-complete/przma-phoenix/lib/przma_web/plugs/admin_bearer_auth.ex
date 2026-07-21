defmodule PRZMAWeb.Plugs.AdminBearerAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = System.fetch_env!("ADMIN_API_TOKEN")

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token == expected ->
        conn
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end