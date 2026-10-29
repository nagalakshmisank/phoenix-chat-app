defmodule Przma.Calendar.View do
  @moduledoc """
  Stored rows (times in microseconds) -> API maps (times as ISO-8601
  strings in the event's own UTC offset, e.g. 2026-11-03T17:00:00+05:30).
  """

  alias Przma.Calendar.{Ids, Recurrence}

  @event_fields ~w(event_id calendar_id owner_did created_by title description location notes
                   color category all_day assigned_to attachments reminders status utc_offset_min
                   edited_by)

  @doc "One occurrence of an event. `occ` = that occurrence's start (= starts_at for one-off events)."
  def event(ev, occ, role, my_note \\ nil) do
    off = ev["utc_offset_min"] || 0
    d = Recurrence.duration(ev)

    ev
    |> Map.take(@event_fields)
    |> Map.merge(%{
      "kind" => "event",
      "starts_at" => Ids.to_local_iso(ev["starts_at"], off),
      "ends_at" => Ids.to_local_iso(ev["ends_at"], off),
      "occurrence_start" => Ids.to_local_iso(occ, off),
      "occurrence_end" => if(ev["ends_at"], do: Ids.to_local_iso(occ + d, off)),
      "recurrence" => recurrence(ev["recurrence"], off),
      "is_recurring" => not is_nil(ev["recurrence"]),
      "my_role" => role,
      "my_note" => my_note,
      "sort_key" => occ
    })
  end

  def recurrence(nil, _off), do: nil

  def recurrence(rule, off) do
    rule
    |> Map.put("until", Ids.to_local_iso(rule["until"], off))
    |> Map.put("exdates", Enum.map(rule["exdates"] || [], &Ids.to_local_iso(&1, off)))
  end

  def invite(row) do
    row
    |> Map.take(~w(calendar_id event_id invitee_did rsvp invited_by status))
    |> Map.put("invited_at", Ids.to_iso(row["invited_at"]))
    |> Map.put("responded_at", Ids.to_iso(row["responded_at"]))
  end
end
