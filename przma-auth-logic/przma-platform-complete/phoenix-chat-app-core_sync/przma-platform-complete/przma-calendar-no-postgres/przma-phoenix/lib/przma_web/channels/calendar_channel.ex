# lib/przma_web/channels/calendar_channel.ex

defmodule PRZMAWeb.CalendarChannel do
  use PRZMAWeb, :channel

  alias PRZMA.Calendar.Events
  alias PRZMA.Identity

  require Logger

  # ── JOIN ────────────────────────────────────────────────────────────────────

  @impl true
  def join("calendar:personal:" <> did, _params, socket) do
    authed_did = socket.assigns[:did]

    if authed_did == did do
      send(self(), {:after_join, did})
      {:ok, assign(socket, :channel_did, did)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join("calendar:circle:" <> rest, _params, socket) do
    # format: circle_did:member_did
    with [circle_did, member_did] <- String.split(rest, ":", parts: 2),
         true                     <- socket.assigns[:did] == member_did,
         :ok                      <- Identity.verify_circle_membership(member_did, circle_did) do
      send(self(), {:after_join_circle, circle_did, member_did})
      {:ok, assign(socket, circle_did: circle_did, channel_did: member_did)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join("calendar:availability:" <> poll_id, _params, socket) do
    {:ok, assign(socket, :poll_id, poll_id)}
  end

  def join(topic, _params, _socket) do
    Logger.warning("Unexpected calendar channel join: #{topic}")
    {:error, %{reason: "unknown_channel"}}
  end

  # ── AFTER JOIN ──────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:after_join, did}, socket) do
    # Deliver pending notifications since last connection
    push(socket, "connection:ready", %{
      did:     did,
      message: "Calendar channel ready",
    })
    {:noreply, socket}
  end

  def handle_info({:after_join_circle, circle_did, member_did}, socket) do
    push(socket, "connection:ready", %{
      circle_did: circle_did,
      member_did: member_did,
    })
    {:noreply, socket}
  end

  # ── CLIENT → SERVER MESSAGES ────────────────────────────────────────────────

  @impl true
  def handle_in("event:subscribe", %{"start" => start, "end" => end_dt}, socket) do
    # Update subscription window — stored in socket assigns
    {:reply, :ok, assign(socket, sub_start: start, sub_end: end_dt)}
  end

  def handle_in("availability:broadcast", payload, socket) do
    did = socket.assigns[:channel_did]
    # Broadcast updated availability to subscribed circles
    broadcast!(socket, "availability:updated", Map.put(payload, "did", did))
    {:reply, :ok, socket}
  end

  def handle_in("presence:update", %{"status" => status}, socket) do
    did = socket.assigns[:channel_did]
    broadcast!(socket, "presence:updated", %{did: did, status: status})
    {:reply, :ok, socket}
  end

  # ── TERMINATE ───────────────────────────────────────────────────────────────

  @impl true
  def terminate(reason, socket) do
    Logger.debug("Calendar channel terminated: #{inspect(reason)}")
    :ok
  end
end
