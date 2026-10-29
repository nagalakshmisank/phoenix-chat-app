defmodule Przma.Calendar.Invites do
  @moduledoc """
  Inviting people to ONE event, and their RSVP.

      {calendar owner}/calendar/private/invites.lance   {cal}-{event}-{did_key}   rsvp, invited_by
      {invitee}/calendar/private/invited.lance          {event_id}                pointer -> owner + calendar

  The pointer is how an invited person sees the event in their agenda even
  though the calendar itself was never shared with them (role "guest").
  RSVP: pending | accepted | tentative | declined. Accepting queues the
  event's reminders for that person.
  """

  alias Przma.Calendar.{Access, Events, Ids, Live, Reminders, View}
  alias Przma.Notify.Notifications
  alias Przma.Social.{Directory, Store}

  @responses ~w(accepted tentative declined)
  @max_invitees 100

  def invite(%{did: me}, calendar_id, event_id, dids) when is_list(dids) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         {:ok, event} <- Events.fetch_active(ctx.owner, calendar_id, event_id),
         dids = dids |> Enum.uniq() |> Kernel.--([me]),
         :ok <- if(length(dids) <= @max_invitees, do: :ok, else: {:error, :too_many_invitees}) do
      new =
        for did <- dids,
            {:ok, _account} <- [Directory.account(did)],
            not active?(ctx.owner, calendar_id, event_id, did),
            :ok <- [write_invite(ctx.owner, calendar_id, event_id, did, me)],
            do: did

      if new != [] do
        Notifications.send(
          new,
          me,
          "EventInvite",
          "calendar",
          "#{Directory.display_name(me)} invited you to \"#{event["title"]}\" on #{Ids.human(event["starts_at"], event["utc_offset_min"])}.",
          %{"calendar_id" => calendar_id, "event_id" => event_id}
        )
      end

      Live.publish(calendar_id, "event_updated", me, %{"event_id" => event_id})
      list(%{did: me}, calendar_id, event_id)
    end
  end

  def rsvp(%{did: me}, calendar_id, event_id, response) do
    with :ok <- if(response in @responses, do: :ok, else: {:error, :invalid_response}),
         {:ok, owner} <- Access.owner_of(calendar_id),
         {:ok, %{"status" => "active"}} <- get(owner, calendar_id, event_id, me),
         {:ok, event} <- Events.fetch_active(owner, calendar_id, event_id),
         :ok <-
           Store.put(owner, "calendar", "invites", Ids.invite_row(calendar_id, event_id, me), %{
             "rsvp" => response,
             "responded_at" => Ids.now_us()
           }),
         :ok <- Store.put(me, "calendar", "invited", event_id, %{"rsvp" => response}) do
      if response in ~w(accepted tentative), do: Reminders.schedule(me, event)

      if event["created_by"] != me do
        Notifications.send(
          [event["created_by"]],
          me,
          "EventRsvp",
          "calendar",
          "#{Directory.display_name(me)} #{response} \"#{event["title"]}\".",
          %{"calendar_id" => calendar_id, "event_id" => event_id, "rsvp" => response}
        )
      end

      Live.publish(calendar_id, "rsvp_changed", me, %{"event_id" => event_id})
      {:ok, true}
    else
      {:ok, _not_active} -> {:error, :not_invited}
      {:error, :not_found} -> {:error, :not_invited}
      err -> err
    end
  end

  @doc "Editors and owner: take someone off the guest list."
  def remove(%{did: me}, calendar_id, event_id, did) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         :ok <- Store.put(ctx.owner, "calendar", "invites", Ids.invite_row(calendar_id, event_id, did), %{"status" => "removed"}),
         :ok <- Store.put(did, "calendar", "invited", event_id, %{"status" => "removed"}) do
      {:ok, true}
    end
  end

  @doc "Guest list of an event — anyone who can see the event may read it."
  def list(%{did: me}, calendar_id, event_id) do
    with {:ok, %{owner: owner}} <- Events.visible(me, calendar_id, event_id),
         {:ok, rows} <- Store.list(owner, "calendar", "invites", prefix: Ids.invite_prefix(calendar_id, event_id), limit: 1000) do
      {:ok, for(%{"status" => "active"} = row <- rows, do: View.invite(row))}
    end
  end

  def get(owner, calendar_id, event_id, did),
    do: Store.get(owner, "calendar", "invites", Ids.invite_row(calendar_id, event_id, did))

  @doc "DIDs of active invitees whose RSVP is in `rsvps`."
  def dids(owner, %{"calendar_id" => calendar_id, "event_id" => event_id}, rsvps) do
    case Store.list(owner, "calendar", "invites", prefix: Ids.invite_prefix(calendar_id, event_id), limit: 1000) do
      {:ok, rows} -> for %{"status" => "active", "rsvp" => r, "invitee_did" => d} <- rows, r in rsvps, do: d
      _ -> []
    end
  end

  @doc "Pointers to events the caller was invited to (not declined)."
  def my_invited(did) do
    case Store.list(did, "calendar", "invited", limit: 1000, descending: true) do
      {:ok, rows} -> Enum.filter(rows, &(&1["status"] == "active" and &1["rsvp"] != "declined"))
      _ -> []
    end
  end

  defp active?(owner, calendar_id, event_id, did) do
    match?({:ok, %{"status" => "active"}}, get(owner, calendar_id, event_id, did))
  end

  defp write_invite(owner, calendar_id, event_id, did, me) do
    with :ok <-
           Store.put(owner, "calendar", "invites", Ids.invite_row(calendar_id, event_id, did), %{
             "calendar_id" => calendar_id,
             "event_id" => event_id,
             "invitee_did" => did,
             "rsvp" => "pending",
             "invited_by" => me,
             "invited_at" => Ids.now_us(),
             "status" => "active"
           }) do
      Store.put(did, "calendar", "invited", event_id, %{
        "calendar_id" => calendar_id,
        "event_id" => event_id,
        "owner_did" => owner,
        "status" => "active"
      })
    end
  end
end
