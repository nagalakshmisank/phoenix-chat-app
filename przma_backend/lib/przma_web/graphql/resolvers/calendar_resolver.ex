defmodule PRZMAWeb.Graphql.Resolvers.CalendarResolver do
  @moduledoc "Calendar service. Logic lives in Przma.Calendar (one facade for the whole app)."

  import PRZMAWeb.Graphql.Resolvers.Helpers

  alias Przma.Calendar

  # queries
  def my_calendars(_args, res), do: run(res, fn me -> Calendar.list_calendars(me.did) end)
  def calendar(%{calendar_id: id}, res), do: run(res, fn me -> Calendar.get_calendar(me.did, id) end)
  def shares(%{calendar_id: id}, res), do: run(res, fn me -> Calendar.list_shares(me, id) end)

  def calendar_events(%{calendar_id: id, from: from, to: to}, res),
    do: run(res, fn me -> Calendar.calendar_events(me, id, from, to) end)

  def agenda(%{from: from, to: to} = args, res),
    do: run(res, fn me -> Calendar.agenda(me, from, to, args[:calendar_ids]) end)

  def event(%{calendar_id: cal, event_id: ev}, res), do: run(res, fn me -> Calendar.get_event(me, cal, ev) end)
  def invites(%{calendar_id: cal, event_id: ev}, res), do: run(res, fn me -> Calendar.list_invites(me, cal, ev) end)

  def holidays(%{region: region, from: from, to: to}, res),
    do: run(res, fn _me -> Calendar.holidays(region, from, to) end)

  # calendars
  def create_calendar(args, res), do: run(res, fn me -> Calendar.create_calendar(me, args) end)
  def update_calendar(%{calendar_id: id} = args, res), do: run(res, fn me -> Calendar.update_calendar(me, id, args) end)
  def archive_calendar(%{calendar_id: id}, res), do: run(res, fn me -> Calendar.archive_calendar(me, id) end)

  # sharing
  def share_with_user(%{calendar_id: id, user_did: did, role: role}, res),
    do: run(res, fn me -> Calendar.share_with_user(me, id, did, role) end)

  def share_with_circle(%{calendar_id: id, circle_id: circle, role: role}, res),
    do: run(res, fn me -> Calendar.share_with_circle(me, id, circle, role) end)

  def unshare(%{calendar_id: id} = args, res), do: run(res, fn me -> Calendar.unshare(me, id, args) end)

  # events
  def create_event(%{calendar_id: id, input: input}, res), do: run(res, fn me -> Calendar.create_event(me, id, input) end)

  def update_event(%{calendar_id: cal, event_id: ev, input: input}, res),
    do: run(res, fn me -> Calendar.update_event(me, cal, ev, input) end)

  def cancel_event(%{calendar_id: cal, event_id: ev}, res), do: run(res, fn me -> Calendar.cancel_event(me, cal, ev) end)

  def skip_occurrence(%{calendar_id: cal, event_id: ev, occurrence_start: occ}, res),
    do: run(res, fn me -> Calendar.skip_occurrence(me, cal, ev, occ) end)

  # invites and notes
  def invite(%{calendar_id: cal, event_id: ev, user_dids: dids}, res),
    do: run(res, fn me -> Calendar.invite(me, cal, ev, dids) end)

  def rsvp(%{calendar_id: cal, event_id: ev, response: r}, res), do: run(res, fn me -> Calendar.rsvp(me, cal, ev, r) end)

  def remove_invite(%{calendar_id: cal, event_id: ev, user_did: did}, res),
    do: run(res, fn me -> Calendar.remove_invite(me, cal, ev, did) end)

  def set_private_note(%{calendar_id: cal, event_id: ev, text: text}, res),
    do: run(res, fn me -> Calendar.set_private_note(me, cal, ev, text) end)
end
