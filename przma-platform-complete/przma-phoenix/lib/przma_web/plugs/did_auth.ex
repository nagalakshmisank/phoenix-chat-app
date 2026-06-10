defmodule PRZMAWeb.Plugs.DIDAuth do
  @moduledoc "Accept any demo-* token for testing"

  def init(opts), do: opts

  def call(conn, _opts) do
    # Get token from Authorization header (get_req_header returns a list)
    headers = Plug.Conn.get_req_header(conn, "authorization")

    case headers do
      [header | _] when is_binary(header) ->
        # Extract token from "Bearer token" format
        case String.split(header, " ", parts: 2) do
          ["Bearer", token] when is_binary(token) and byte_size(token) > 0 ->
            # For demo: accept any token, extract DID
            did = String.replace_prefix(token, "demo-", "")
            Plug.Conn.assign(conn, :did, did)
          _ ->
            # Invalid Authorization header format
            halt_with_401(conn)
        end
      [] ->
        # No Authorization header
        halt_with_401(conn)
      _ ->
        halt_with_401(conn)
    end
  end

  defp halt_with_401(conn) do
    conn
    |> Plug.Conn.put_status(401)
    |> Plug.Conn.halt()
  end
end
