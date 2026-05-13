# lib/przma/calendar/jobs/analytics_jobs.ex
#
# Phase 6 Oban jobs for analytics, companion context, and adapter training.

defmodule PRZMA.Calendar.Jobs.MorningBriefing do
  @moduledoc """
  Delivers the morning calendar briefing to the companion.
  Scheduled daily at the user's configured morning time.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.CompanionContext

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    case CompanionContext.morning_briefing(did) do
      {:ok, _}      -> :ok
      {:error, msg} ->
        require Logger
        Logger.warning("Morning briefing failed", did: did, error: msg)
        :ok  # Best-effort
    end
  end

  @doc "Schedule morning briefing for a DID at a specific time today"
  def schedule_today(did, hour \\ 8, minute \\ 0, timezone \\ "UTC") do
    now      = DateTime.utc_now()
    today    = DateTime.to_date(now)
    naive_dt = NaiveDateTime.new!(today, Time.new!(hour, minute, 0))

    # Convert from user timezone to UTC
    trigger_at = DateTime.from_naive!(naive_dt, timezone)

    if DateTime.compare(trigger_at, now) == :gt do
      %{did: did}
      |> new(scheduled_at: trigger_at)
      |> Oban.insert()
    else
      # Already past — schedule for tomorrow
      tomorrow   = Date.add(today, 1)
      naive_tom  = NaiveDateTime.new!(tomorrow, Time.new!(hour, minute, 0))
      trigger_tom = DateTime.from_naive!(naive_tom, timezone)
      %{did: did}
      |> new(scheduled_at: trigger_tom)
      |> Oban.insert()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.AnalyticsRefresh do
  @moduledoc """
  Refreshes cached analytics for a DID.
  Triggered after significant calendar changes (batch events, etc.).
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.{Analytics, CompanionContext}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    # Run analytics and push updated context
    with {:ok, _insights} <- Analytics.generate_insights(did),
         {:ok, _context}  <- CompanionContext.push_update(did, "analytics_refresh") do
      Analytics.maybe_trigger_adapter_training(did)
      :ok
    else
      {:error, msg} ->
        require Logger
        Logger.warning("Analytics refresh failed", did: did, error: msg)
        :ok
    end
  end

  def enqueue(did) do
    %{did: did}
    |> new(schedule_in: 30)  # 30 second delay to batch rapid changes
    |> Oban.insert()
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.EmbeddingBackfill do
  @moduledoc """
  Backfills missing embeddings for all events in a vault namespace.
  Run nightly or triggered manually for a DID.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 3

  alias PRZMA.Calendar.Intelligence.CompanionContext

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did, "space" => space}}) do
    case CompanionContext.backfill_embeddings(did, space) do
      {:ok, result} ->
        require Logger
        Logger.info("Embedding backfill complete",
          did: did, space: space,
          processed: result.processed, embedded: result.embedded)
        :ok
      {:error, msg} ->
        {:error, msg}
    end
  end

  def enqueue(did, space \\ "core") do
    %{did: did, space: space}
    |> new(schedule_in: 300)  # 5 min delay — non-urgent
    |> Oban.insert()
  end

  @doc "Schedule nightly backfill for all active DIDs"
  def schedule_nightly do
    # Phase 6: iterate active DIDs from PostgreSQL user table
    # For now: triggered per-user on demand
    :ok
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.AdapterTraining do
  @moduledoc """
  Triggers personal companion adapter retraining.
  Scheduled when new vault entry count exceeds the retrain threshold.
  Actual training runs locally on the user's device or server.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 1

  alias PRZMA.Calendar.Intelligence.CompanionContext
  alias PRZMAWeb.Endpoint

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    require Logger
    Logger.info("Triggering companion adapter training", did: did)

    # Signal the user's client to run local adapter training
    Endpoint.broadcast("calendar:personal:#{did}", "companion:train_adapter", %{
      trigger:   "threshold_reached",
      namespace: "calendar",
      message:   "New calendar data available for personal adapter update",
    })

    # Record checkpoint so threshold resets
    CompanionContext.record_training_checkpoint(did)
    :ok
  end

  def enqueue(did) do
    %{did: did}
    |> new(schedule_in: 3600)  # 1 hour delay — training is non-urgent
    |> Oban.insert()
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.WeeklyInsights do
  @moduledoc """
  Generates and delivers weekly calendar insights to the companion.
  Runs every Monday morning.
  """
  use Oban.Worker, queue: :intelligence, max_attempts: 2

  alias PRZMA.Calendar.Intelligence.Analytics
  alias PRZMAWeb.Endpoint

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did}}) do
    case Analytics.weekly_report(did) do
      {:ok, report} ->
        Endpoint.broadcast("calendar:personal:#{did}", "companion:weekly_insights", %{
          type:   "weekly_calendar_insights",
          report: report,
          prompt: build_weekly_prompt(report),
        })
        :ok

      {:error, msg} ->
        require Logger
        Logger.warning("Weekly insights failed", did: did, error: msg)
        :ok
    end
  end

  def schedule_weekly(did) do
    # Schedule for next Monday 9am UTC
    now     = DateTime.utc_now()
    days_to_monday = Integer.mod(1 - Date.day_of_week(DateTime.to_date(now)), 7)
    days_to_monday = if days_to_monday == 0, do: 7, else: days_to_monday
    monday  = Date.add(DateTime.to_date(now), days_to_monday)
    trigger = DateTime.new!(monday, ~T[09:00:00])

    %{did: did}
    |> new(scheduled_at: trigger)
    |> Oban.insert()
  end

  defp build_weekly_prompt(report) do
    summary = report["summary"] || "Here is your weekly calendar summary."
    insight = report["top_insight"]

    if insight do
      "#{summary} #{insight["body"]}"
    else
      summary
    end
  end
end
