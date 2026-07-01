# lib/przma/calendar/intelligence/analytics.ex
#
# Calendar analytics context for companion and UI.
# Queries Lance files via DuckDB Rustler NIF.
# All analytics run on the user's own vault — never on PRZMA servers.

defmodule PRZMA.Calendar.Intelligence.Analytics do
  alias PRZMA.Calendar.NIF
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── TIME RANGE HELPERS ───────────────────────────────────────────────────

  def last_n_days(n) do
    now   = DateTime.utc_now()
    start = DateTime.add(now, -n * 86400, :second)
    {DateTime.to_unix(start, :microsecond), DateTime.to_unix(now, :microsecond)}
  end

  def date_range(start_dt, end_dt) do
    {DateTime.to_unix(start_dt, :microsecond), DateTime.to_unix(end_dt, :microsecond)}
  end

  # ── TIME DISTRIBUTION ────────────────────────────────────────────────────

  @doc """
  Get time distribution across categories for a period.
  Returns breakdown by category, hour of day, and day of week.
  """
  def time_distribution(did, opts \\ []) do
    {start_micros, end_micros} = period_micros(opts, 30)
    case NIF.time_distribution(@base_path, did, start_micros, end_micros) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── PRACTICE ADHERENCE ───────────────────────────────────────────────────

  @doc "Get adherence statistics for a specific practice"
  def practice_adherence(did, practice_title, opts \\ []) do
    {start_micros, end_micros} = period_micros(opts, 90)
    case NIF.practice_adherence(@base_path, did, practice_title, start_micros, end_micros) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Get adherence for all practices in the vault"
  def all_practices_adherence(did, opts \\ []) do
    {start_micros, end_micros} = period_micros(opts, 90)

    # First list unique practice titles
    with {:ok, dist} <- time_distribution(did, opts) do
      practice_count = get_in(dist, ["by_category", "PRACTICE"]) || 0

      if practice_count == 0 do
        {:ok, []}
      else
        # Get practice titles from analytics
        # Phase 6: query distinct titles from Lance
        {:ok, []}
      end
    end
  end

  # ── MEETING PATTERNS ─────────────────────────────────────────────────────

  @doc "Get meeting patterns for a period"
  def meeting_patterns(did, opts \\ []) do
    {start_micros, end_micros} = period_micros(opts, 30)
    case NIF.meeting_patterns(@base_path, did, start_micros, end_micros) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── COMPANION INSIGHTS ───────────────────────────────────────────────────

  @doc """
  Generate actionable companion insights from calendar analytics.
  Returns prioritised list of insights for companion delivery.
  """
  def generate_insights(did, opts \\ []) do
    {start_micros, end_micros} = period_micros(opts, 30)
    case NIF.generate_insights(@base_path, did, start_micros, end_micros) do
      {:ok, json}   ->
        insights = Jason.decode!(json)
        enriched  = enrich_with_context(insights, did)
        {:ok, enriched}
      {:error, msg} ->
        Logger.warning("Insight generation failed", did: did, error: msg)
        {:ok, []}  # Fail gracefully — insights are non-critical
    end
  end

  # ── WEEKLY REPORT ────────────────────────────────────────────────────────

  @doc """
  Build a weekly calendar report for companion delivery.
  Combines time distribution, meeting patterns, and insights.
  """
  def weekly_report(did) do
    {start_micros, end_micros} = last_n_days(7)

    with {:ok, dist}     <- time_distribution(did, start_micros: start_micros, end_micros: end_micros),
         {:ok, patterns} <- meeting_patterns(did, start_micros: start_micros, end_micros: end_micros),
         {:ok, insights} <- generate_insights(did, start_micros: start_micros, end_micros: end_micros) do

      report = %{
        period:           "last_7_days",
        generated_at:     DateTime.utc_now() |> DateTime.to_unix(:microsecond),
        summary:          build_summary_text(dist, patterns),
        time_distribution: dist,
        meeting_patterns:  patterns,
        insights:          insights,
        top_insight:       List.first(insights),
      }
      {:ok, report}
    end
  end

  # ── EMBEDDING ────────────────────────────────────────────────────────────

  @doc "Generate embedding for text (for semantic search)"
  def embed_text(text, context \\ "query") do
    case NIF.embed_text(@base_path, text, context) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  @doc "Embed and update a single event's embedding in Lance"
  def embed_and_update_event(did, event_id, space \\ "core") do
    NIF.embed_and_update_event(@base_path, did, event_id, space)
  end

  @doc "Rank a list of events by semantic similarity to a query"
  def semantic_rank(candidates, query_text) do
    with {:ok, query_vec} <- embed_text(query_text, "query") do
      candidates_json = Jason.encode!(
        Enum.map(candidates, fn e ->
          %{"id" => e["id"], "embedding" => e["embedding"] || List.duplicate(0.0, 768)}
        end)
      )
      case NIF.rank_events_by_similarity(@base_path, candidates_json, Jason.encode!(query_vec), 10) do
        {:ok, json}   -> {:ok, Jason.decode!(json)}
        {:error, msg} -> {:error, msg}
      end
    end
  end

  # ── ADAPTER TRAINING TRIGGERS ────────────────────────────────────────────

  @doc """
  Check if the companion personal adapter should be retrained.
  Returns true if enough new vault entries exist since last training.
  """
  def should_retrain_adapter?(did) do
    # Check number of events/tasks created since last adapter checkpoint
    last_trained = get_last_adapter_training(did)
    new_entries  = count_entries_since(did, last_trained)
    new_entries >= adapter_retrain_threshold()
  end

  @doc "Trigger companion adapter retraining if threshold is met"
  def maybe_trigger_adapter_training(did) do
    if should_retrain_adapter?(did) do
      PRZMA.Calendar.Jobs.AdapterTraining.enqueue(did)
    else
      {:ok, :no_retrain_needed}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp period_micros(opts, default_days) do
    case {opts[:start_micros], opts[:end_micros]} do
      {s, e} when not is_nil(s) and not is_nil(e) -> {s, e}
      _ ->
        last_n_days(opts[:days] || default_days)
    end
  end

  defp enrich_with_context(insights, did) do
    # Add DID-specific context to each insight (Phase 6: Arc Engine enrichment)
    Enum.map(insights, fn insight ->
      Map.put(insight, "did", did)
    end)
  end

  defp build_summary_text(dist, patterns) do
    total   = dist["total_events"] || 0
    meetings = get_in(dist, ["by_category", "MEETING"]) || 0
    mins    = dist["total_busy_mins"] || 0
    avg_meeting = patterns["avg_duration_mins"] || 0.0

    cond do
      total == 0 ->
        "No calendar events this period."

      meetings == 0 ->
        "#{total} events scheduled, #{format_mins(mins)} of calendar time."

      true ->
        "#{total} events this period — #{meetings} meetings averaging #{round(avg_meeting)} minutes. " <>
        "Total scheduled time: #{format_mins(mins)}."
    end
  end

  defp format_mins(mins) when mins < 60, do: "#{mins} minutes"
  defp format_mins(mins) do
    h = div(mins, 60)
    m = rem(mins, 60)
    if m == 0, do: "#{h} hours", else: "#{h}h #{m}m"
  end

  defp get_last_adapter_training(_did) do
    # Phase 6: read from companion/adapter_checkpoint.lance
    DateTime.utc_now() |> DateTime.add(-7 * 86400, :second)  # Default: 7 days ago
  end

  defp count_entries_since(did, since_dt) do
    since_micros = DateTime.to_unix(since_dt, :microsecond)
    now_micros   = DateTime.utc_now() |> DateTime.to_unix(:microsecond)

    case NIF.calendar_analytics(@base_path, did, "event_count_by_category",
           Jason.encode!(%{start_micros: since_micros, end_micros: now_micros})) do
      {:ok, json} ->
        json |> Jason.decode!() |> Map.values() |> Enum.sum()
      _ ->
        0
    end
  end

  defp adapter_retrain_threshold do
    Application.get_env(:przma, [:companion, :retrain_threshold], 50)
  end
end
