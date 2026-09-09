defmodule PRZMAWeb.Plugs.GraphiqlPageAuth do
  @behaviour Plug
  def init(opts), do: opts
  def call(%Plug.Conn{method: "GET"} = conn, _opts), do: conn
  def call(conn, opts), do: PRZMAWeb.Plugs.KeycloakAuth.call(conn, opts)
end