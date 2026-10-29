defmodule Przma.Calendar do
  @moduledoc """
  PRZMA Calendar service — the ONE entry point other parts of the app use
  (GraphQL resolvers, chat "schedule a meeting", registration, later AI
  agents). Callers never touch the calendar tables directly.

  `me` is always %{did: ...} built from the verified Keycloak token.

  Storage: LanceDB doc tables in S3 through Przma.Social.Store, namespace
  "calendar" (see Przma.Calendar.Ids for every row id):

      {owner}/calendar/private/calendars.lance       calendars
      {owner}/calendar/private/events.lance          events (+ recurrence, shared notes, reminders)
      {owner}/calendar/private/shares.lance          who the calendar is shared with
      {owner}/calendar/private/invites.lance         guest list + RSVP per event
      {user}/calendar/private/subscriptions.lance    calendars shared with me
      {user}/calendar/private/invited.lance          events I was invited to
      {user}/calendar/private/private_notes.lance    my private notes
      {system}/calendar/private/index.lance          calendar_id -> owner
      {system}/calendar/private/circle_calendars     circle_id -> shared calendars
      {system}/calendar/private/reminders.lance      reminder queue (by fire time)
      {system}/calendar/private/scheduler.lance      scheduler cursor
      {system}/calendar/public/holidays.lance        regional holidays
  """

  alias Przma.Calendar.{Calendars, Events, Holidays, Invites, Notes, Shares}

  # calendars
  defdelegate ensure_default_calendar(did), to: Calendars, as: :ensure_default
  defdelegate list_calendars(did), to: Calendars, as: :list_mine
  defdelegate get_calendar(did, calendar_id), to: Calendars, as: :get_for
  defdelegate create_calendar(me, attrs), to: Calendars, as: :create
  defdelegate update_calendar(me, calendar_id, attrs), to: Calendars, as: :update
  defdelegate archive_calendar(me, calendar_id), to: Calendars, as: :archive

  # sharing
  defdelegate share_with_user(me, calendar_id, did, role), to: Shares
  defdelegate share_with_circle(me, calendar_id, circle_id, role), to: Shares
  defdelegate unshare(me, calendar_id, opts), to: Shares
  defdelegate list_shares(me, calendar_id), to: Shares, as: :list

  # events
  defdelegate create_event(me, calendar_id, input), to: Events, as: :create
  defdelegate update_event(me, calendar_id, event_id, input), to: Events, as: :update
  defdelegate cancel_event(me, calendar_id, event_id), to: Events, as: :cancel
  defdelegate skip_occurrence(me, calendar_id, event_id, occurrence_iso), to: Events
  defdelegate get_event(me, calendar_id, event_id), to: Events, as: :get
  defdelegate calendar_events(me, calendar_id, from_iso, to_iso), to: Events, as: :list_calendar
  defdelegate agenda(me, from_iso, to_iso, calendar_ids \\ nil), to: Events

  # invites, notes, holidays
  defdelegate invite(me, calendar_id, event_id, dids), to: Invites
  defdelegate rsvp(me, calendar_id, event_id, response), to: Invites
  defdelegate remove_invite(me, calendar_id, event_id, did), to: Invites, as: :remove
  defdelegate list_invites(me, calendar_id, event_id), to: Invites, as: :list
  defdelegate set_private_note(me, calendar_id, event_id, text), to: Notes, as: :set
  defdelegate holidays(region, from_iso, to_iso), to: Holidays, as: :list
end
