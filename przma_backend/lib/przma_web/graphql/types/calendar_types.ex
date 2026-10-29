defmodule PRZMAWeb.Graphql.Types.CalendarTypes do
  @moduledoc """
  Calendar service API. Times are ISO-8601 strings with an offset, e.g.
  "2026-11-03T17:00:00+05:30" (input) — returned in the event's own offset.
  Logic lives in Przma.Calendar.*; results are string-keyed maps (the
  schema's middleware reads both string and atom keys).
  """
  use Absinthe.Schema.Notation

  alias PRZMAWeb.Graphql.Resolvers.CalendarResolver

  # ── objects ──────────────────────────────────────────────────────────

  object :calendar do
    field :calendar_id, :string
    field :owner_did, :string
    field :name, :string
    @desc "personal | family | friends | business | school"
    field :calendar_type, :string
    field :color, :string
    field :timezone, :string
    @desc "Holiday region: IN, IN_TN, ..."
    field :region, :string
    field :is_default, :boolean
    @desc "owner | editor | viewer"
    field :my_role, :string
    field :status, :string
  end

  object :calendar_share do
    field :calendar_id, :string
    @desc "user | circle"
    field :target_type, :string
    @desc "DID or circle id"
    field :target, :string
    @desc "viewer | editor"
    field :role, :string
    field :shared_by, :string
    field :status, :string
  end

  object :calendar_attachment do
    @desc "Content hash from uploadFile / uploadBlob"
    field :cas, :string
    field :name, :string
  end

  object :calendar_recurrence do
    @desc "daily | weekly | monthly | yearly"
    field :freq, :string
    field :interval, :integer
    @desc "weekly: MO TU WE TH FR SA SU"
    field :by_day, list_of(:string)
    field :count, :integer
    field :until, :string
    field :exdates, list_of(:string)
  end

  @desc "One occurrence of an event (a repeating event appears once per occurrence), or a holiday."
  object :calendar_event do
    @desc "event | holiday"
    field :kind, :string
    field :event_id, :string
    field :calendar_id, :string
    field :owner_did, :string
    field :created_by, :string
    field :title, :string
    field :description, :string
    field :location, :string
    @desc "Shared notes: everyone who can see the event"
    field :notes, :string
    @desc "My private note (only I can see it)"
    field :my_note, :string
    field :color, :string
    field :category, :string
    field :all_day, :boolean
    field :assigned_to, :string
    field :attachments, list_of(:calendar_attachment)
    @desc "Minutes before the start"
    field :reminders, list_of(:integer)
    field :recurrence, :calendar_recurrence
    field :is_recurring, :boolean
    @desc "Series start / end"
    field :starts_at, :string
    field :ends_at, :string
    @desc "This occurrence's start / end"
    field :occurrence_start, :string
    field :occurrence_end, :string
    field :utc_offset_min, :integer
    @desc "confirmed | cancelled"
    field :status, :string
    @desc "owner | editor | viewer | guest (invited to this event only)"
    field :my_role, :string
    field :edited_by, :string
    @desc "Holidays only: public | optional | festival"
    field :holiday_kind, :string
    field :region, :string
  end

  object :calendar_invite do
    field :calendar_id, :string
    field :event_id, :string
    field :invitee_did, :string
    @desc "pending | accepted | tentative | declined"
    field :rsvp, :string
    field :invited_by, :string
    field :invited_at, :string
    field :responded_at, :string
  end

  @desc "Live change on a calendar: event_created, event_updated, event_cancelled, rsvp_changed, calendar_updated, calendar_shared."
  object :calendar_update do
    field :calendar_id, :string
    field :event, :string
    field :event_id, :string
    field :actor_did, :string
    field :at, :string
  end

  # ── inputs ───────────────────────────────────────────────────────────

  input_object :calendar_attachment_input do
    field :cas, non_null(:string)
    field :name, :string
  end

  input_object :calendar_recurrence_input do
    field :freq, non_null(:string)
    field :interval, :integer
    field :by_day, list_of(:string)
    field :count, :integer
    field :until, :string
    field :exdates, list_of(:string)
  end

  @desc "Fields you leave out are not changed (update). Send null to clear a field."
  input_object :calendar_event_input do
    field :title, :string
    field :description, :string
    field :location, :string
    field :notes, :string
    field :color, :string
    field :category, :string
    field :starts_at, :string
    field :ends_at, :string
    field :all_day, :boolean
    field :assigned_to, :string
    field :attachments, list_of(:calendar_attachment_input)
    field :reminders, list_of(:integer)
    field :recurrence, :calendar_recurrence_input
  end

  # ── queries ──────────────────────────────────────────────────────────

  object :calendar_queries do
    @desc "Every calendar I can see (my own + shared with me + shared with my circles). Creates my default calendar if missing."
    field :my_calendars, list_of(:calendar) do
      resolve &CalendarResolver.my_calendars/2
    end

    field :calendar, :calendar do
      arg :calendar_id, non_null(:string)
      resolve &CalendarResolver.calendar/2
    end

    @desc "Owner only."
    field :calendar_shares, list_of(:calendar_share) do
      arg :calendar_id, non_null(:string)
      resolve &CalendarResolver.shares/2
    end

    @desc "Occurrences of one calendar in [from, to), plus its region's holidays."
    field :calendar_events, list_of(:calendar_event) do
      arg :calendar_id, non_null(:string)
      arg :from, non_null(:string)
      arg :to, non_null(:string)
      resolve &CalendarResolver.calendar_events/2
    end

    @desc "My agenda in [from, to): all my calendars + events I'm invited to + holidays. calendarIds narrows it."
    field :my_agenda, list_of(:calendar_event) do
      arg :from, non_null(:string)
      arg :to, non_null(:string)
      arg :calendar_ids, list_of(:string)
      resolve &CalendarResolver.agenda/2
    end

    field :calendar_event, :calendar_event do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      resolve &CalendarResolver.event/2
    end

    field :event_invites, list_of(:calendar_invite) do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      resolve &CalendarResolver.invites/2
    end

    field :holidays, list_of(:calendar_event) do
      arg :region, non_null(:string)
      arg :from, non_null(:string)
      arg :to, non_null(:string)
      resolve &CalendarResolver.holidays/2
    end
  end

  # ── mutations ────────────────────────────────────────────────────────

  object :calendar_mutations do
    field :create_calendar, :calendar do
      arg :name, non_null(:string)
      arg :calendar_type, :string
      arg :color, :string
      arg :timezone, :string
      arg :region, :string
      resolve &CalendarResolver.create_calendar/2
    end

    @desc "Owner only."
    field :update_calendar, :calendar do
      arg :calendar_id, non_null(:string)
      arg :name, :string
      arg :color, :string
      arg :timezone, :string
      arg :region, :string
      resolve &CalendarResolver.update_calendar/2
    end

    @desc "Owner only; not the default calendar."
    field :archive_calendar, :boolean do
      arg :calendar_id, non_null(:string)
      resolve &CalendarResolver.archive_calendar/2
    end

    @desc "Owner only. role: viewer | editor"
    field :share_calendar_with_user, :calendar_share do
      arg :calendar_id, non_null(:string)
      arg :user_did, non_null(:string)
      arg :role, non_null(:string)
      resolve &CalendarResolver.share_with_user/2
    end

    @desc "Owner only, and the owner must be a member of the circle. role: viewer | editor"
    field :share_calendar_with_circle, :calendar_share do
      arg :calendar_id, non_null(:string)
      arg :circle_id, non_null(:string)
      arg :role, non_null(:string)
      resolve &CalendarResolver.share_with_circle/2
    end

    @desc "Owner only. Pass userDid OR circleId."
    field :unshare_calendar, :boolean do
      arg :calendar_id, non_null(:string)
      arg :user_did, :string
      arg :circle_id, :string
      resolve &CalendarResolver.unshare/2
    end

    @desc "Owner or editor of the calendar."
    field :create_event, :calendar_event do
      arg :calendar_id, non_null(:string)
      arg :input, non_null(:calendar_event_input)
      resolve &CalendarResolver.create_event/2
    end

    field :update_event, :calendar_event do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :input, non_null(:calendar_event_input)
      resolve &CalendarResolver.update_event/2
    end

    field :cancel_event, :boolean do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      resolve &CalendarResolver.cancel_event/2
    end

    @desc "Repeating events: skip one occurrence (pass its occurrenceStart)."
    field :skip_occurrence, :boolean do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :occurrence_start, non_null(:string)
      resolve &CalendarResolver.skip_occurrence/2
    end

    field :invite_to_event, list_of(:calendar_invite) do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :user_dids, non_null(list_of(non_null(:string)))
      resolve &CalendarResolver.invite/2
    end

    @desc "response: accepted | tentative | declined"
    field :rsvp_event, :boolean do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :response, non_null(:string)
      resolve &CalendarResolver.rsvp/2
    end

    field :remove_invite, :boolean do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :user_did, non_null(:string)
      resolve &CalendarResolver.remove_invite/2
    end

    @desc "My private note on an event (empty string clears it)."
    field :set_private_note, :string do
      arg :calendar_id, non_null(:string)
      arg :event_id, non_null(:string)
      arg :text, non_null(:string)
      resolve &CalendarResolver.set_private_note/2
    end
  end
end
