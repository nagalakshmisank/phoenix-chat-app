defmodule Przma.Calendar.Reminders do
  @moduledoc """
  Reminder queue. Each event carries "reminders" = minutes before the
  start, e.g. [15, 1440] = 15 minutes and 1 day before.

  One row per (person, event, minutes) for the NEXT occurrence only, in a
  shared table owned by the calendar system DID, with an id that starts
  with the fire time, so "everything due now" is one range read:

      {system}/calendar/private/reminders.lance
        {fire_at 17 digits}-{did_key}-{event_id}-{minutes}
        user_did, owner_did, calendar_id, event_id, occurrence_start,
        minutes_before, fire_at, status: pending | sent | skipped

  Przma.Calendar.ReminderScheduler reads due rows every minute and calls
  fire/1. Firing re-checks the event (still there, not cancelled, same
  time, reminder still set, person can still see it) — so when an event
  is moved, the old rows are simply skipped and new rows are queued; no
  row ever has to be found and deleted. A repeating event queues its next
  occurrence when the current reminder fires.

  The notification goes through Przma.Notify.Notifications (category
  "calendar"): stored in the person's inbox ("sys" thread) and pushed
  live via notificationReceived, so offline users see it later.
  """

  require Logger

  alias Przma.Calendar.{Calendars, Events, Ids, Recurrence}
  alias Przma.Notify.Notifications

  @doc "Queues the next reminder(s) of `event` for `did`."
  def schedule(did, event) do
    Enum.each(event["reminders"] || [], &schedule_one(did, event, &1, nil))
    :ok
  end

  @doc "Called by the scheduler for each due, pending row."
  def fire(%{"status" => "pending"} = row) do
    %{"owner_did" => owner, "calendar_id" => cal, "event_id" => ev_id, "user_did" => did} = row
    minutes = row["minutes_before"]
    occ = row["occurrence_start"]

    result =
      with {:ok, event} <- Events.fetch_active(owner, cal, ev_id),
           true <- minutes in (event["reminders"] || []),
           {:ok, _} <- Events.visible(did, cal, ev_id) do
        if Recurrence.occurs?(event, occ), do: send_notification(did, event, occ, minutes)
        # Next occurrence of a repeating event (same id as an update would
        # queue, so it is written once even if both happen).
        if event["recurrence"], do: schedule_one(did, event, minutes, occ)
        if Recurrence.occurs?(event, occ), do: "sent", else: "skipped"
      else
        _ -> "skipped"
      end

    mark(row, result)
  end

  def fire(_row), do: :ok

  # ── private ──────────────────────────────────────────────────────────

  # Next occurrence whose fire time is still in the future (and after `after_occ`).
  defp schedule_one(did, event, minutes, after_occ) do
    lead = minutes * Ids.minute_us()
    now = Ids.now_us()
    floor = Enum.max([now + lead, after_occ || 0])

    case Recurrence.next_after(event, floor) do
      nil ->
        :ok

      occ ->
        fire_at = occ - lead

        Calendars.system_put("reminders", Ids.reminder_row(fire_at, did, event["event_id"], minutes), %{
          "user_did" => did,
          "owner_did" => event["owner_did"],
          "calendar_id" => event["calendar_id"],
          "event_id" => event["event_id"],
          "occurrence_start" => occ,
          "minutes_before" => minutes,
          "fire_at" => fire_at,
          "status" => "pending"
        })
    end
  end

  defp send_notification(did, event, occ, minutes) do
    text = "Reminder: \"#{event["title"]}\" #{lead_text(minutes)} — #{Ids.human(occ, event["utc_offset_min"])}"

    Notifications.send(
      [did],
      event["created_by"] || event["owner_did"],
      "EventReminder",
      "calendar",
      text,
      %{
        "calendar_id" => event["calendar_id"],
        "event_id" => event["event_id"],
        "occurrence_start" => Ids.to_local_iso(occ, event["utc_offset_min"])
      }
    )
  end

  defp mark(row, status) do
    Calendars.system_put("reminders", row["id"], %{"status" => status, "processed_at" => Ids.now_us()})
  end

  defp lead_text(0), do: "starts now"
  defp lead_text(m) when m < 60, do: "in #{m} min"
  defp lead_text(m) when rem(m, 1440) == 0, do: "in #{div(m, 1440)} day(s)"
  defp lead_text(m) when rem(m, 60) == 0, do: "in #{div(m, 60)} hour(s)"
  defp lead_text(m), do: "in #{m} min"
end
