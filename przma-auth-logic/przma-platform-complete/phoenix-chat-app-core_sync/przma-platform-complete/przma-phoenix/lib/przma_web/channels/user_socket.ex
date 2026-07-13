defmodule PRZMAWeb.UserSocket do
  use Phoenix.Socket
  alias PRZMA.Auth.Token

  channel "circle:*", PRZMAWeb.CircleChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Token.verify(token) do
      {:ok, did} -> {:ok, assign(socket, :did, did)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.did}"
end