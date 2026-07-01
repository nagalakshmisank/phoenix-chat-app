defmodule PRZMAWeb.Plugs.DIDAuth do
  @moduledoc """
  Verifies the signed bearer token from PRZMA.Auth.Token and assigns the
  decoded DID to conn.assigns[:did]. Pure cryptographic verification — no
  Lance read, no database, no session table hit on this path.
  """

  import Plug.Conn
  alias PRZMA.Auth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         ["Bearer", token] <- String.split(header, " ", parts: 2),
         {:ok, did} <- Token.verify(token) do
      assign(conn, :did, did)
    else
      _ -> halt_with_401(conn)
    end
  end

  defp halt_with_401(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end