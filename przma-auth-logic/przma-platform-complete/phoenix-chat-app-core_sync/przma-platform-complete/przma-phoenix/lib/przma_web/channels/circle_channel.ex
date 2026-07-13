defmodule PRZMAWeb.CircleChannel do
  use PRZMAWeb, :channel
  alias PRZMA.Social.CircleSync
  alias PRZMAWeb.Presence

  @impl true
  def join("circle:" <> circle_id, _params, socket) do
    did = socket.assigns.did

    with {:ok, owner_did} <- CircleSync.resolve_owner_did(did, circle_id),
         {:ok, _role}     <- CircleSync.get_role(owner_did, circle_id, did) do
      send(self(), :after_join)
      {:ok, assign(socket, :circle_id, circle_id)}
    else
      _ -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    {:ok, _} =
      Presence.track(socket, socket.assigns.did, %{
        online_at: System.os_time(:second)
      })

    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end

  @impl true
  def handle_in("typing", _payload, socket) do
    broadcast_from(socket, "typing", %{did: socket.assigns.did})
    {:noreply, socket}
  end
end