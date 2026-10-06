defmodule PRZMAWeb.UserSocket do
  @moduledoc """
  Websocket for GraphQL subscriptions (Absinthe over Phoenix channels).

  Connect to  ws://<host>:<port>/socket/websocket?token=<Keycloak access token>
  The token is verified exactly like an HTTP request (KeycloakAuth.verify/1)
  and the same identity is placed in the GraphQL context.
  """

  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: PRZMAWeb.Graphql.Schema

  alias PRZMAWeb.Plugs.KeycloakAuth

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case KeycloakAuth.verify(token) do
      {:ok, %{"preferred_username" => username} = claims} when is_binary(username) ->
        did = "did:przma:" <> username

        context = %{
          did: did,
          tenant_uuid: claims["sub"],
          storage_tier: 1,
          token_claims: claims,
          roles: []
        }

        socket =
          socket
          |> assign(:did, did)
          |> Absinthe.Phoenix.Socket.put_options(context: context)

        {:ok, socket}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:" <> socket.assigns.did
end
