defmodule PRZMAWeb.DemoController do
  @moduledoc """
  DEMO ONLY. Serves the demo console and exchanges username/password for a
  Keycloak token on the server side, so the browser never sees the client
  secret and no CORS setup is needed.

  Off unless DEMO_MODE=true. Needs KC_CLIENT_ID and KC_CLIENT_SECRET in the
  server's environment. Remove the route before any real deployment.
  """
  use PRZMAWeb, :controller

  def page(conn, _params) do
    if enabled?() do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, Application.app_dir(:przma, "priv/demo/index.html"))
    else
      send_resp(conn, 404, "not found")
    end
  end

  def login(conn, %{"username" => user, "password" => pass}) when is_binary(user) and is_binary(pass) do
    with true <- enabled?(),
         {:ok, client_id, secret} <- client(),
         {:ok, status, body} <- token_request(client_id, secret, user, pass) do
      conn |> put_status(status) |> put_resp_content_type("application/json") |> send_resp(status, body)
    else
      false -> send_resp(conn, 404, "not found")
      {:error, :no_client} -> conn |> put_status(500) |> json(%{error: "KC_CLIENT_ID / KC_CLIENT_SECRET not set on the server"})
      {:error, reason} -> conn |> put_status(502) |> json(%{error: "keycloak unreachable: #{inspect(reason)}"})
    end
  end

  def login(conn, _), do: conn |> put_status(400) |> json(%{error: "username and password required"})

  defp enabled?, do: System.get_env("DEMO_MODE") == "true"

  defp client do
    case {System.get_env("KC_CLIENT_ID"), System.get_env("KC_CLIENT_SECRET")} do
      {id, secret} when is_binary(id) and is_binary(secret) and id != "" and secret != "" -> {:ok, id, secret}
      _ -> {:error, :no_client}
    end
  end

  defp token_url do
    base = System.get_env("KEYCLOAK_URL", "http://przma-dev-keycloak:8080")
    realm = System.get_env("KEYCLOAK_REALM", "przma")
    "#{base}/realms/#{realm}/protocol/openid-connect/token"
  end

  defp token_request(client_id, secret, user, pass) do
    form =
      {:form,
       [
         {"client_id", client_id},
         {"client_secret", secret},
         {"grant_type", "password"},
         {"username", user},
         {"password", pass}
       ]}

    case :hackney.post(token_url(), [], form, [:with_body, recv_timeout: 10_000]) do
      {:ok, status, _headers, body} -> {:ok, status, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
