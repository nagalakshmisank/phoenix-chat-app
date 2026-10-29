defmodule Przma.Calendar.Events do
  @moduledoc """
  Events: create, update, cancel, skip one occurrence, read one, and read
  a date range (one calendar or the caller's whole agenda).

      {calendar owner}/calendar/private/events.lance   {calendar_id}-{event_id}

  An event always lives in the database of the CALENDAR's owner, whoever
  created it (an editor adding to a shared Family calendar writes into the
  owner's database). Repeating events are one row, expanded on read
  (Przma.Calendar.Recurrence). Cancel = status "cancelled" (no deletes).

  Who can see an event: anyone with a role on its calendar (Access), plus
  people invited to that single event (role "guest", see Invites).
  """

  alias Przma.Calendar.{Access, Calendars, Holidays, Ids, Invites, Live, Notes, Recurrence, Reminders, Rows, View}
  alias Przma.Notify.Notifications
  alias Przma.Social.{Directory, Store}

  @text_fields %{
    title: 200,
    description: 5_000,
    location: 300,
    notes: 10_000,
    color: 20,
    category: 50
  }
  @max_reminders 5
  @max_reminder_minutes 40_320
  @max_range_days 400

  # ── writes ───────────────────────────────────────────────────────────

  def create(%{did: me}, calendar_id, input) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         {:ok, fields} <- build(input, nil),
         :ok <- if(is_binary(fields["title"]), do: :ok, else: {:error, :title_required}),
         :ok <- if(is_integer(fields["starts_at"]), do: :ok, else: {:error, :starts_at_required}) do
      event_id = Ids.event_id()

      event =
        Map.merge(fields, %{
          "event_id" => event_id,
          "calendar_id" => calendar_id,
          "owner_did" => ctx.owner,
          "created_by" => me,
          "status" => "confirmed"
        })

      with :ok <- Store.put(ctx.owner, "calendar", "events", Ids.event_row(calendar_id, event_id), event) do
        Reminders.schedule(me, event)
        Live.publish(calendar_id, "event_created", me, %{"event_id" => event_id})
        {:ok, View.event(event, event["starts_at"], ctx.role)}
      end
    end
  end

  @doc "Changes only the fields sent. Editors and owner only."
  def update(%{did: me}, calendar_id, event_id, input) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         {:ok, event} <- fetch_active(ctx.owner, calendar_id, event_id),
         {:ok, changes} <- build(input, event) do
      changes = Map.merge(changes, %{"edited_by" => me, "edited_at" => Ids.now_us()})
      updated = Map.merge(event, changes)

      with :ok <- Store.put(ctx.owner, "calendar", "events", Ids.event_row(calendar_id, event_id), changes) do
        if timing_changed?(changes), do: reschedule_all(ctx.owner, updated)
        tell_invitees(me, ctx.owner, updated, "EventUpdated", "updated")
        Live.publish(calendar_id, "event_updated", me, %{"event_id" => event_id})
        {:ok, View.event(updated, updated["starts_at"], ctx.role, Notes.get(me, event_id))}
      end
    end
  end

  def cancel(%{did: me}, calendar_id, event_id) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         {:ok, event} <- fetch_active(ctx.owner, calendar_id, event_id),
         :ok <-
           Store.put(ctx.owner, "calendar", "events", Ids.event_row(calendar_id, event_id), %{
             "status" => "cancelled",
             "edited_by" => me,
             "edited_at" => Ids.now_us()
           }) do
      tell_invitees(me, ctx.owner, event, "EventCancelled", "cancelled")
      Live.publish(calendar_id, "event_cancelled", me, %{"event_id" => event_id})
      {:ok, true}
    end
  end

  @doc "Repeating events: drop one occurrence (e.g. no meeting on a holiday)."
  def skip_occurrence(%{did: me}, calendar_id, event_id, occurrence_iso) do
    with {:ok, ctx} <- Access.resolve_edit(me, calendar_id),
         {:ok, %{"recurrence" => %{} = rule} = event} <- fetch_active(ctx.owner, calendar_id, event_id),
         {:ok, occ, _} <- Ids.parse_time(occurrence_iso),
         :ok <- if(Recurrence.occurs?(event, occ), do: :ok, else: {:error, :not_an_occurrence}) do
      rule = Map.update(rule, "exdates", [occ], &Enum.uniq([occ | &1]))

      with :ok <-
             Store.put(ctx.owner, "calendar", "events", Ids.event_row(calendar_id, event_id), %{
               "recurrence" => rule,
               "edited_by" => me,
               "edited_at" => Ids.now_us()
             }) do
        Live.publish(calendar_id, "event_updated", me, %{"event_id" => event_id})
        {:ok, true}
      end
    else
      {:ok, _not_recurring} -> {:error, :not_recurring}
      err -> err
    end
  end

  # ── reads ────────────────────────────────────────────────────────────

  @doc "One event (series view) with my role and my private note."
  def get(%{did: me}, calendar_id, event_id) do
    with {:ok, %{event: event, role: role}} <- visible(me, calendar_id, event_id) do
      {:ok, View.event(event, event["starts_at"], role, Notes.get(me, event_id))}
    end
  end

  @doc "Occurrences in [from, to) of ONE calendar."
  def list_calendar(%{did: me}, calendar_id, from_iso, to_iso) do
    with {:ok, from, to} <- range(from_iso, to_iso),
         {:ok, %{owner: owner, role: role, calendar: calendar}} <- Access.resolve(me, calendar_id) do
      notes = Notes.map_for(me)
      items = expand_calendar(owner, calendar_id, role, notes, from, to)
      holidays = Holidays.overlay([calendar["region"]], from, to)
      {:ok, sort(items ++ holidays)}
    end
  end

  @doc """
  The caller's agenda for [from, to): every calendar they can see, plus
  single events they were invited to, plus regional holidays.
  `calendar_ids` narrows it to some calendars (nil = all).
  """
  def agenda(%{did: me}, from_iso, to_iso, calendar_ids \\ nil) do
    with {:ok, from, to} <- range(from_iso, to_iso),
         {:ok, calendars} <- Calendars.list_mine(me) do
      calendars =
        if calendar_ids, do: Enum.filter(calendars, &(&1["calendar_id"] in calendar_ids)), else: calendars

      notes = Notes.map_for(me)
      seen = MapSet.new(calendars, & &1["calendar_id"])

      from_calendars =
        Enum.flat_map(calendars, fn c ->
          expand_calendar(c["owner_did"], c["calendar_id"], c["my_role"], notes, from, to)
        end)

      from_invites =
        for row <- Invites.my_invited(me),
            not MapSet.member?(seen, row["calendar_id"]),
            {:ok, event} <- [fetch_active(row["owner_did"], row["calendar_id"], row["event_id"])],
            occ <- Recurrence.occurrences(event, from, to) do
          View.event(event, occ, "guest", notes[event["event_id"]])
        end

      regions = calendars |> Enum.map(& &1["region"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      {:ok, sort(from_calendars ++ from_invites ++ Holidays.overlay(regions, from, to))}
    end
  end

  # ── shared helpers (also used by Invites, Notes, Reminders) ──────────

  def fetch(owner, calendar_id, event_id) do
    if Ids.valid?(calendar_id) and Ids.valid?(event_id),
      do: Store.get(owner, "calendar", "events", Ids.event_row(calendar_id, event_id)),
      else: {:error, :not_found}
  end

  def fetch_active(owner, calendar_id, event_id) do
    case fetch(owner, calendar_id, event_id) do
      {:ok, %{"status" => "cancelled"}} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "{:ok, %{owner, event, role}} if `did` may see this event (calendar role or invite)."
  def visible(did, calendar_id, event_id) do
    case Access.resolve(did, calendar_id) do
      {:ok, ctx} ->
        with {:ok, event} <- fetch_active(ctx.owner, calendar_id, event_id),
             do: {:ok, %{owner: ctx.owner, event: event, role: ctx.role}}

      {:error, :forbidden} ->
        with {:ok, owner} <- Access.owner_of(calendar_id),
             {:ok, %{"status" => "active"}} <- Invites.get(owner, calendar_id, event_id, did),
             {:ok, event} <- fetch_active(owner, calendar_id, event_id) do
          {:ok, %{owner: owner, event: event, role: "guest"}}
        else
          _ -> {:error, :forbidden}
        end

      err ->
        err
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp expand_calendar(owner, calendar_id, role, notes, from, to) do
    case Rows.all(owner, "events", Ids.event_prefix(calendar_id)) do
      {:ok, rows} ->
        for %{"status" => "confirmed"} = event <- rows,
            occ <- Recurrence.occurrences(event, from, to),
            do: View.event(event, occ, role, notes[event["event_id"]])

      _ ->
        []
    end
  end

  defp sort(items), do: Enum.sort_by(items, & &1["sort_key"])

  defp range(from_iso, to_iso) do
    with {:ok, from, _} <- Ids.parse_time(from_iso),
         {:ok, to, _} <- Ids.parse_time(to_iso) do
      cond do
        to <= from -> {:error, :invalid_range}
        to - from > @max_range_days * 86_400_000_000 -> {:error, :range_too_long}
        true -> {:ok, from, to}
      end
    end
  end

  # Builds the stored fields from client input. `existing` = nil on create.
  defp build(input, existing) do
    input = Map.new(input, fn {k, v} -> {to_atom_key(k), v} end)

    with {:ok, acc} <- text_fields(input),
         {:ok, acc} <- times(input, existing, acc),
         {:ok, acc} <- reminders(input, acc),
         {:ok, acc} <- recurrence(input, acc),
         {:ok, acc} <- attachments(input, acc) do
      acc =
        acc
        |> put_present(input, :all_day, "all_day", &(&1 == true))
        |> put_present(input, :assigned_to, "assigned_to", & &1)

      {:ok, if(existing, do: acc, else: Map.merge(%{"all_day" => false, "reminders" => default_reminders()}, acc))}
    end
  end

  defp text_fields(input) do
    Enum.reduce_while(@text_fields, {:ok, %{}}, fn {key, max}, {:ok, acc} ->
      case Map.fetch(input, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          if key == :title, do: {:halt, {:error, :title_required}}, else: {:cont, {:ok, Map.put(acc, to_string(key), nil)}}

        {:ok, value} when is_binary(value) ->
          value = String.trim(value)

          cond do
            key == :title and value == "" -> {:halt, {:error, :title_required}}
            String.length(value) > max -> {:halt, {:error, String.to_atom("#{key}_too_long")}}
            true -> {:cont, {:ok, Map.put(acc, to_string(key), value)}}
          end

        _ ->
          {:halt, {:error, String.to_atom("invalid_#{key}")}}
      end
    end)
  end

  # starts_at / ends_at as ISO strings. Moving only the start keeps the
  # event's duration. All-day events without an end last one day.
  defp times(input, existing, acc) do
    old_s = existing && existing["starts_at"]
    old_e = existing && existing["ends_at"]

    with {:ok, s, offset} <- parse_opt(input[:starts_at], old_s, existing && existing["utc_offset_min"]),
         {:ok, e, _} <- parse_opt(input[:ends_at], nil, nil) do
      all_day = Map.get(input, :all_day, existing && existing["all_day"]) == true

      e =
        cond do
          is_integer(e) -> e
          is_nil(s) -> nil
          is_integer(old_s) and is_integer(old_e) -> s + (old_e - old_s)
          all_day -> s + 86_400_000_000
          true -> s + 3_600_000_000
        end

      cond do
        is_integer(s) and is_integer(e) and e < s ->
          {:error, :ends_before_start}

        Map.has_key?(input, :starts_at) or Map.has_key?(input, :ends_at) ->
          {:ok, Map.merge(acc, %{"starts_at" => s, "ends_at" => e, "utc_offset_min" => offset || 0})}

        true ->
          {:ok, acc}
      end
    end
  end

  defp parse_opt(nil, old, old_offset), do: {:ok, old, old_offset}

  defp parse_opt(iso, _old, _old_offset) do
    case Ids.parse_time(iso) do
      {:ok, us, offset} -> {:ok, us, offset}
      _ -> {:error, :invalid_time}
    end
  end

  defp reminders(%{reminders: nil}, acc), do: {:ok, Map.put(acc, "reminders", [])}

  defp reminders(%{reminders: list}, acc) when is_list(list) do
    list = list |> Enum.uniq() |> Enum.sort()

    if length(list) <= @max_reminders and Enum.all?(list, &(is_integer(&1) and &1 in 0..@max_reminder_minutes)),
      do: {:ok, Map.put(acc, "reminders", list)},
      else: {:error, :invalid_reminders}
  end

  defp reminders(_input, acc), do: {:ok, acc}

  defp recurrence(input, acc) do
    if Map.has_key?(input, :recurrence) do
      with {:ok, rule} <- Recurrence.normalize(input[:recurrence]), do: {:ok, Map.put(acc, "recurrence", rule)}
    else
      {:ok, acc}
    end
  end

  # Attachments point at files already uploaded through uploadFile /
  # uploadBlob (content hash = cas), so no file bytes live in the event.
  defp attachments(%{attachments: nil}, acc), do: {:ok, Map.put(acc, "attachments", [])}

  defp attachments(%{attachments: list}, acc) when is_list(list) and length(list) <= 20 do
    items =
      for item <- list do
        item = Map.new(item, fn {k, v} -> {to_string(k), v} end)
        %{"cas" => item["cas"], "name" => item["name"]}
      end

    if Enum.all?(items, &(is_binary(&1["cas"]) and &1["cas"] != "")),
      do: {:ok, Map.put(acc, "attachments", items)},
      else: {:error, :invalid_attachments}
  end

  defp attachments(%{attachments: _}, _acc), do: {:error, :invalid_attachments}
  defp attachments(_input, acc), do: {:ok, acc}

  defp put_present(acc, input, key, field, fun) do
    if Map.has_key?(input, key), do: Map.put(acc, field, fun.(input[key])), else: acc
  end

  defp timing_changed?(changes), do: Enum.any?(~w(starts_at ends_at reminders recurrence), &Map.has_key?(changes, &1))

  # Creator + everyone who accepted gets their reminders queued again.
  # Rows queued for the old time are skipped when they come due.
  defp reschedule_all(owner, event) do
    people = [event["created_by"] | Invites.dids(owner, event, ~w(accepted tentative))]
    Enum.each(Enum.uniq(people), &Reminders.schedule(&1, event))
  end

  defp tell_invitees(me, owner, event, activity, verb) do
    recipients = Invites.dids(owner, event, ~w(pending accepted tentative)) -- [me]

    if recipients != [] do
      when_text = Ids.human(event["starts_at"], event["utc_offset_min"])

      Notifications.send(
        recipients,
        me,
        activity,
        "calendar",
        "#{Directory.display_name(me)} #{verb} \"#{event["title"]}\" (#{when_text}).",
        %{"calendar_id" => event["calendar_id"], "event_id" => event["event_id"]}
      )
    end

    :ok
  end

  defp default_reminders do
    :przma |> Application.get_env(:calendar, []) |> Keyword.get(:default_reminders, [15])
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: String.to_existing_atom(k)
end
