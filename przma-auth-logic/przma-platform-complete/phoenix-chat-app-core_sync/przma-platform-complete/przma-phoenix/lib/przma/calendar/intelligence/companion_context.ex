# lib/przma/calendar/intelligence/companion_context.ex
#
# Full companion calendar context assembler.
# Integrates: today's schedule, upcoming events, open tasks,
# practice streaks, meeting load, and analytical insights.
# This is the primary context feed from calendar → companion.

defmodule PRZMA.Calendar.Intelligence.CompanionContext do
  alias PRZMA.Calendar.{Events, Tasks, NIF}
  alias PRZMA.Calendar.Intelligence.{Analytics, PreBrief}
  alias PRZMAWeb.Endpoint
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── CONTEXT ASSEMBLY ─────────────────────────────────────────────────────

  @doc """
  Assemble full calendar context for the companion.
  Called on session start and when calendar changes occur.
  Returns a rich context map for companion use.
  """
  def assemble(did, opts \\ []) do
    now        = DateTime.utc_now()
    horizon_h  = opts[:horizon_hours] || 48
    end_dt     = DateTime.add(now, horizon_h * 3600, :second)

    # Parallel context assembly
    [today_task, upcoming_task, tasks_task, insights_task] =
      [
        Task.async(fn -> fetch_today_events(did, now) end),
        Task.async(fn -> fetch_upcoming_events(did, now, end_dt) end),
        Task.async(fn -> fetch_pending_tasks(did) end),
        Task.async(fn -> Analytics.generate_insights(did, days: 14) end),
      ]

    today_events    = Task.await(today_task,    5000) |> ok_or([])
    upcoming_events = Task.await(upcoming_task, 5000) |> ok_or([])
    pending_tasks   = Task.await(tasks_task,    5000) |> ok_or([])
    insights        = Task.await(insights_task, 5000) |> ok_or([])

    next_event       = find_next_event(today_events ++ upcoming_events, now)
    active_practices = filter_practices(today_events)
    overdue_tasks    = filter_overdue(pending_tasks, now)

    context = %{
      assembled_at:    DateTime.to_unix(now, :microsecond),
      did:             did,
      time_now:        DateTime.to_iso8601(now),
      timezone:        opts[:timezone] || "UTC",

      # Today's schedule
      today: %{
        events:      today_events,
        event_count: length(today_events),
        busy_mins:   total_busy_mins(today_events),
        has_meetings: Enum.any?(today_events, fn e -> e["category"] == "MEETING" end),
      },

      # Coming up
      upcoming:     upcoming_events,
      next_event:   next_event,
      mins_to_next: mins_to_next_event(next_event, now),

      # Tasks
      pending_tasks:  pending_tasks,
      overdue_tasks:  overdue_tasks,
      overdue_count:  length(overdue_tasks),

      # Practices
      active_practices: active_practices,
      practice_count:   length(active_practices),

      # Insights
      insights:         insights,
      top_insight:      List.first(insights),

      # Companion prompt context
      morning_briefing: build_morning_briefing(today_events, pending_tasks, active_practices),
      situation:        assess_situation(today_events, overdue_tasks, now),
    }

    {:ok, context}
  end

  @doc """
  Push updated calendar context to companion channel.
  Called after any significant calendar change.
  """
  def push_update(did, reason \\ "calendar_change") do
    case assemble(did) do
      {:ok, context} ->
        Endpoint.broadcast("calendar:personal:#{did}", "calendar:context_updated", %{
          reason:  reason,
          context: context,
        })
        {:ok, context}

      {:error, msg} ->
        Logger.warning("Context push failed", did: did, reason: msg)
        {:error, msg}
    end
  end

  @doc """
  Build the morning briefing text for companion delivery.
  Called by MorningBriefing Oban job at configured time.
  """
  def morning_briefing(did) do
    with {:ok, context} <- assemble(did, horizon_hours: 24) do
      briefing = %{
        type:       "morning_briefing",
        text:       context.morning_briefing,
        today:      context.today,
        practices:  context.active_practices,
        tasks:      Enum.take(context.pending_tasks, 5),
        insights:   Enum.take(context.insights, 2),
        next_event: context.next_event,
      }
      Endpoint.broadcast("calendar:personal:#{did}", "companion:morning_briefing", briefing)
      {:ok, briefing}
    end
  end

  # ── EMBEDDING PIPELINE ───────────────────────────────────────────────────

  @doc """
  Embed all calendar events for a DID that have zero embeddings.
  Called periodically to keep the semantic index current.
  """
  def backfill_embeddings(did, space \\ "core") do
    {:ok, events} = Events.list(did, space: space, limit: 1000)

    empty = Enum.filter(events, fn e ->
      emb = e["embedding"] || []
      Enum.all?(emb, fn v -> v == 0.0 end)
    end)

    Logger.info("Backfilling embeddings", did: did, count: length(empty))

    results = Enum.map(empty, fn event ->
      case NIF.embed_and_update_event(@base_path, did, event["id"], space) do
        {:ok, _}     -> {:ok, event["id"]}
        {:error, msg} -> {:error, {event["id"], msg}}
      end
    end)

    successes = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    {:ok, %{processed: length(empty), embedded: successes}}
  end

  # ── ADAPTER TRAINING CHECKPOINT ──────────────────────────────────────────

  @doc """
  Record a companion adapter training checkpoint.
  Resets the counter for retrain threshold checking.
  """
  def record_training_checkpoint(did) do
    checkpoint = %{
      trained_at: DateTime.utc_now() |> DateTime.to_unix(:microsecond),
      did:        did,
    }
    # Store checkpoint in companion namespace (Phase 6: Lance write)
    Logger.info("Adapter training checkpoint recorded", did: did)
    {:ok, checkpoint}
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp fetch_today_events(did, now) do
    day_start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00]) |> DateTime.to_unix(:microsecond)
    day_end   = now |> DateTime.to_date() |> DateTime.new!(~T[23:59:59]) |> DateTime.to_unix(:microsecond)

    Events.list(did,
      space:        "core",
      start_micros: day_start,
      end_micros:   day_end,
      status:       "confirmed",
      limit:        50
    )
  end

  defp fetch_upcoming_events(did, now, end_dt) do
    Events.list(did,
      space:        "core",
      start_micros: DateTime.to_unix(now, :microsecond),
      end_micros:   DateTime.to_unix(end_dt, :microsecond),
      status:       "confirmed",
      limit:        20
    )
  end

  defp fetch_pending_tasks(did) do
    Tasks.list(did, space: "core", status: "active", limit: 50)
  end

  defp find_next_event(events, now) do
    now_micros = DateTime.to_unix(now, :microsecond)
    events
    |> Enum.sort_by(fn e -> e["start_at"] end)
    |> Enum.find(fn e -> e["start_at"] >= now_micros end)
  end

  defp mins_to_next_event(nil, _now), do: nil
  defp mins_to_next_event(event, now) do
    start_micros = event["start_at"]
    now_micros   = DateTime.to_unix(now, :microsecond)
    div(start_micros - now_micros, 60_000_000)
  end

  defp filter_practices(events) do
    Enum.filter(events, fn e -> e["category"] == "PRACTICE" end)
  end

  defp filter_overdue(tasks, now) do
    now_micros = DateTime.to_unix(now, :microsecond)
    Enum.filter(tasks, fn t ->
      due = t["due_at"]
      due && due < now_micros && t["status"] == "active"
    end)
  end

  defp total_busy_mins(events) do
    Enum.reduce(events, 0, fn e, acc ->
      start = e["start_at"] || 0
      stop  = e["end_at"]   || start
      acc + div(stop - start, 60_000_000)
    end)
  end

  defp build_morning_briefing(today_events, pending_tasks, practices) do
    greeting  = time_greeting()
    event_str = build_event_summary(today_events)
    task_str  = build_task_summary(pending_tasks)
    prac_str  = build_practice_reminder(practices)

    [greeting, event_str, task_str, prac_str]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp time_greeting do
    hour = DateTime.utc_now().hour
    cond do
      hour < 12 -> "Good morning."
      hour < 17 -> "Good afternoon."
      true      -> "Good evening."
    end
  end

  defp build_event_summary([]),     do: "You have no events scheduled today."
  defp build_event_summary(events) do
    count    = length(events)
    meetings = Enum.count(events, fn e -> e["category"] == "MEETING" end)
    first    = List.first(events)

    base = "You have #{count} event#{if count == 1, do: "", else: "s"} today"
    meet = if meetings > 0, do: ", including #{meetings} meeting#{if meetings == 1, do: "", else: "s"}", else: ""
    next = if first, do: ". First up: #{first["title"]} at #{format_time(first["start_at"])}", else: ""

    "#{base}#{meet}#{next}."
  end

  defp build_task_summary([]), do: nil
  defp build_task_summary(tasks) do
    overdue = Enum.count(tasks, fn t ->
      t["due_at"] && t["due_at"] < DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    end)
    if overdue > 0 do
      "You have #{overdue} overdue task#{if overdue == 1, do: "", else: "s"}."
    else
      nil
    end
  end

  defp build_practice_reminder([]),        do: nil
  defp build_practice_reminder(practices) do
    names = Enum.map_join(Enum.take(practices, 2), " and ", fn p -> p["title"] end)
    "Your #{names} practice#{if length(practices) == 1, do: " is", else: "s are"} scheduled today."
  end

  defp assess_situation(today_events, overdue_tasks, now) do
    meeting_count = Enum.count(today_events, fn e -> e["category"] == "MEETING" end)
    overdue_count = length(overdue_tasks)

    cond do
      overdue_count >= 3 and meeting_count >= 4 ->
        %{type: "high_load", label: "Heavy day", suggestion: "Prioritise ruthlessly"}
      overdue_count >= 3 ->
        %{type: "overdue_pressure", label: "Overdue items need attention", suggestion: "Review and re-prioritise"}
      meeting_count >= 5 ->
        %{type: "meeting_heavy", label: "Meeting-heavy day", suggestion: "Protect some focus time"}
      true ->
        %{type: "normal", label: "Normal day", suggestion: nil}
    end
  end

  defp format_time(micros) when is_integer(micros) do
    dt = DateTime.from_unix!(micros, :microsecond)
    "#{String.pad_leading(to_string(dt.hour), 2, "0")}:#{String.pad_leading(to_string(dt.minute), 2, "0")}"
  end
  defp format_time(_), do: "unknown time"

  defp ok_or({:ok, v}, _), do: v
  defp ok_or({:error, _}, default), do: default
  defp ok_or(other, default), do: default
end
