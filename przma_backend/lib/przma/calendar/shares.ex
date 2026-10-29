defmodule Przma.Calendar.Shares do
  @moduledoc """
  Sharing a calendar with a person or with a circle (owner only).

  Share with a USER (most common — family member, colleague):
      {owner}/calendar/private/shares.lance          {cal}-u_{did_key}  role, status
      {user}/calendar/private/subscriptions.lance    {cal}              pointer -> owner (their "my calendars")
      + a notification in the user's inbox (category "calendar")

  Share with a CIRCLE (optional — only when the owner chooses it):
      {owner}/calendar/private/shares.lance          {cal}-c_{circle_id}
      {system}/calendar/private/circle_calendars     {circle_id}-{cal}  (members find it from their circles)
      No row per member: membership is checked live by Access.

  Unsharing marks the rows "revoked" (the doc store has no deletes).
  """

  alias Przma.Calendar.{Access, Calendars, Ids, Live}
  alias Przma.Circle.Members
  alias Przma.Notify.{Notifications, Publisher}
  alias Przma.Social.{Directory, Store}

  @roles ~w(viewer editor)

  def share_with_user(%{did: me}, calendar_id, target_did, role) do
    with :ok <- check_role(role),
         {:ok, %{owner: owner, calendar: calendar}} <- Access.resolve_owner(me, calendar_id),
         :ok <- if(target_did == owner, do: {:error, :cannot_share_with_owner}, else: :ok),
         {:ok, _account} <- Directory.account(target_did),
         share = share_row(calendar_id, "user", target_did, role, me),
         :ok <- Store.put(owner, "calendar", "shares", Ids.share_user_row(calendar_id, target_did), share),
         :ok <-
           Store.put(target_did, "calendar", "subscriptions", calendar_id, %{
             "calendar_id" => calendar_id,
             "owner_did" => owner,
             "role" => role,
             "name" => calendar["name"],
             "status" => "active"
           }) do
      Notifications.send(
        [target_did],
        me,
        "CalendarShared",
        "calendar",
        "#{Directory.display_name(me)} shared the calendar \"#{calendar["name"]}\" with you (#{role}).",
        %{"calendar_id" => calendar_id}
      )

      Live.publish(calendar_id, "calendar_shared", me)
      {:ok, share}
    end
  end

  def share_with_circle(%{did: me}, calendar_id, circle_id, role) do
    with :ok <- check_role(role),
         {:ok, %{owner: owner, calendar: calendar}} <- Access.resolve_owner(me, calendar_id),
         {:ok, %{role: my_circle_role}} <- Members.context(me, circle_id),
         :ok <- if(my_circle_role in ~w(owner admin member), do: :ok, else: {:error, :forbidden}),
         share = share_row(calendar_id, "circle", circle_id, role, me),
         :ok <- Store.put(owner, "calendar", "shares", Ids.share_circle_row(calendar_id, circle_id), share),
         :ok <-
           Calendars.system_put("circle_calendars", Ids.circle_calendar_row(circle_id, calendar_id), %{
             "circle_id" => circle_id,
             "calendar_id" => calendar_id,
             "owner_did" => owner,
             "role" => role,
             "status" => "active"
           }) do
      Publisher.circle_event(circle_id, "calendar_shared", %{"actor_did" => me, "calendar_name" => calendar["name"]})
      Live.publish(calendar_id, "calendar_shared", me)
      {:ok, share}
    end
  end

  @doc "Owner only. Pass user_did OR circle_id."
  def unshare(%{did: me}, calendar_id, opts) do
    with {:ok, %{owner: owner}} <- Access.resolve_owner(me, calendar_id) do
      revoked = %{"status" => "revoked", "revoked_at" => Ids.now_us()}

      cond do
        is_binary(opts[:user_did]) ->
          with :ok <- Store.put(owner, "calendar", "shares", Ids.share_user_row(calendar_id, opts[:user_did]), revoked),
               :ok <- Store.put(opts[:user_did], "calendar", "subscriptions", calendar_id, revoked),
               do: {:ok, true}

        is_binary(opts[:circle_id]) ->
          with :ok <- Store.put(owner, "calendar", "shares", Ids.share_circle_row(calendar_id, opts[:circle_id]), revoked),
               :ok <-
                 Calendars.system_put("circle_calendars", Ids.circle_calendar_row(opts[:circle_id], calendar_id), revoked),
               do: {:ok, true}

        true ->
          {:error, :user_did_or_circle_id_required}
      end
    end
  end

  @doc "Owner only: who the calendar is shared with."
  def list(%{did: me}, calendar_id) do
    with {:ok, %{owner: owner}} <- Access.resolve_owner(me, calendar_id),
         {:ok, rows} <- Store.list(owner, "calendar", "shares", prefix: Ids.share_prefix(calendar_id), limit: 1000) do
      {:ok, Enum.filter(rows, &(&1["status"] == "active"))}
    end
  end

  defp share_row(calendar_id, target_type, target, role, me) do
    %{
      "calendar_id" => calendar_id,
      "target_type" => target_type,
      "target" => target,
      "role" => role,
      "status" => "active",
      "shared_by" => me,
      "shared_at" => Ids.now_us()
    }
  end

  defp check_role(role) when role in @roles, do: :ok
  defp check_role(_), do: {:error, :invalid_role}
end
