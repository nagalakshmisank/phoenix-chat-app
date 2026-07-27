# lib/przma_web/controllers/calendar/analytics_controller.ex

defmodule PRZMAWeb.Calendar.AnalyticsController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Intelligence.{Analytics, CompanionContext}

  # GET /api/v1/calendar/analytics/time-distribution
  def time_distribution(conn, params) do
    did  = conn.assigns.did
    opts = build_opts(params)
    case Analytics.time_distribution(did, opts) do
      {:ok, dist}   -> json(conn, dist)
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/analytics/meeting-patterns
  def meeting_patterns(conn, params) do
    did  = conn.assigns.did
    opts = build_opts(params)
    case Analytics.meeting_patterns(did, opts) do
      {:ok, patterns} -> json(conn, patterns)
      {:error, msg}   -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/analytics/practice-adherence/:title
  def practice_adherence(conn, %{"title" => title} = params) do
    did  = conn.assigns.did
    opts = build_opts(params)
    case Analytics.practice_adherence(did, title, opts) do
      {:ok, adherence} -> json(conn, adherence)
      {:error, msg}    -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/analytics/insights
  def insights(conn, params) do
    did  = conn.assigns.did
    opts = build_opts(params)
    case Analytics.generate_insights(did, opts) do
      {:ok, insights} -> json(conn, %{insights: insights})
      {:error, msg}   -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/analytics/weekly-report
  def weekly_report(conn, _params) do
    did = conn.assigns.did
    case Analytics.weekly_report(did) do
      {:ok, report}  -> json(conn, report)
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/companion/context
  def companion_context(conn, params) do
    did  = conn.assigns.did
    opts = [
      horizon_hours: String.to_integer(params["horizon_hours"] || "48"),
      timezone:      params["timezone"] || "UTC",
    ]
    case CompanionContext.assemble(did, opts) do
      {:ok, context} -> json(conn, context)
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/analytics/embed
  def embed(conn, %{"text" => text} = params) do
    did     = conn.assigns.did
    context = params["context"] || "query"
    case Analytics.embed_text(text, context) do
      {:ok, vector}  -> json(conn, %{vector: vector, dim: length(vector)})
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/analytics/semantic-rank
  def semantic_rank(conn, %{"candidates" => candidates, "query" => query}) do
    did = conn.assigns.did
    case Analytics.semantic_rank(candidates, query) do
      {:ok, ranked}  -> json(conn, %{ranked: ranked})
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/analytics/backfill-embeddings
  def backfill_embeddings(conn, params) do
    did   = conn.assigns.did
    space = params["space"] || "core"
    PRZMA.Calendar.Jobs.EmbeddingBackfill.enqueue(did, space)
    json(conn, %{status: "queued", message: "Embedding backfill scheduled"})
  end

  defp build_opts(params) do
    opts = []
    opts = if d = params["days"],  do: [{:days, String.to_integer(d)} | opts],   else: opts
    opts = if s = params["start"], do: [{:start_micros, parse_micros(s)} | opts], else: opts
    opts = if e = params["end"],   do: [{:end_micros, parse_micros(e)} | opts],   else: opts
    opts
  end

  defp parse_micros(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _            -> nil
    end
  end
end
