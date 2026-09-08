defmodule PRZMAWeb.Graphql.Context do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    context = %{
      did: conn.assigns.did,
      tenant_uuid: conn.assigns.tenant_uuid,
      roles: conn.assigns[:roles] || []
    }

    Absinthe.Plug.put_options(conn, context: context)
  end
end