# lib/api/holnn_controller.ex
#
# HOLNN REST API
#
# GET    /api/v1/holnn/state                 — current filter states + sapience index
# GET    /api/v1/holnn/history               — sapience history (sparkline data)
# POST   /api/v1/holnn/checkin/quick         — quick check-in (CLEAR/FOGGED per filter)
# POST   /api/v1/holnn/checkin/deep          — deep check-in (0-100 + reflections)
# POST   /api/v1/holnn/checkin/weekly        — weekly review with narrative
# GET    /api/v1/holnn/prompts               — self-assessment prompts per filter
# POST   /api/v1/holnn/infer                 — trigger immediate inference (async)
# GET    /api/v1/holnn/training/status       — training readiness and progress
# POST   /api/v1/holnn/training/trigger      — manually trigger training (sovereign only)
# GET    /api/v1/holnn/practices             — practice recommendations for current state

defmodule PRZMAWeb.HOLNNController do
  use PRZMAWeb, :controller
  require Logger

  alias PRZMA.HOLNN.{CheckIn, Inference, DataCollector, TrainingJob, CompanionIntegration}

  # ── STATE ─────────────────────────────────────────────────────────────────

  # GET /api/v1/holnn/state
  def state(conn, _params) do
    did = conn.assigns.did

    case Inference.run(did) do
      {:ok, result} ->
        json(conn, %{
          filter_states:   result.filter_states,
          matrix:          result.matrix,
          sapience_index:  result.sapience_index,
          sapience_band:   result.sapience_band,
          sapience_detail: result.sapience_detail,
          pb_accumulator:  result.pb_accumulator,
          source:          result.source,
          confidence:      result.confidence,
          practices:       CompanionIntegration.recommend_practices(did),
        })

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v1/holnn/history?days=30
  def history(conn, params) do
    did  = conn.assigns.did
    days = String.to_integer(params["days"] || "30")

    case CheckIn.history(did, days) do
      {:ok, snapshots} ->
        # Format as sparkline-ready data
        sparkline = Enum.map(snapshots, fn s ->
          %{
            date:           format_date(s["snapshot_at"]),
            sapience_index: s["sapience_index"] || 0.0,
            filter_states:  parse_filter_states_brief(s["filter_states_json"]),
          }
        end)

        {:ok, trend} = CompanionIntegration.sapience_trend(did, days)
        json(conn, %{snapshots: sparkline, trend: trend, count: length(snapshots)})

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  # ── CHECK-IN ─────────────────────────────────────────────────────────────

  # POST /api/v1/holnn/checkin/quick
  # Body: {"filter_states": {"body": "clear", "heart": "fogged", ...}}
  def quick_checkin(conn, %{"filter_states" => states}) do
    did = conn.assigns.did

    filter_states = Enum.map(states, fn {k, v} ->
      atom_k = String.to_existing_atom(k)
      atom_v = String.to_existing_atom(v)
      {atom_k, atom_v}
    end) |> Enum.into(%{})

    case CheckIn.quick_checkin(did, filter_states) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(%{
          snapshot:       result.snapshot,
          label_count:    result.label_count,
          next_training:  result.next_training,
          practices:      CompanionIntegration.recommend_practices(did),
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end
  def quick_checkin(conn, _params) do
    conn |> put_status(400) |> json(%{error: "filter_states required", expected:
      "{'filter_states': {'body': 'clear', 'senses': 'fogged', ...}}"})
  end

  # POST /api/v1/holnn/checkin/deep
  # Body: {"assessments": {"body": {"score": 72, "reflection": "..."}, ...}}
  def deep_checkin(conn, %{"assessments" => assessments}) do
    did = conn.assigns.did

    normalized = Enum.map(assessments, fn {k, v} ->
      atom_k = String.to_existing_atom(k)
      {atom_k, %{
        score:      v["score"] || 50,
        reflection: v["reflection"],
      }}
    end) |> Enum.into(%{})

    case CheckIn.deep_checkin(did, normalized) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(%{
          snapshot:          result.snapshot,
          reflections_saved: result.reflections_saved,
          label_count:       result.label_count,
          next_training:     result.next_training,
        })

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v1/holnn/checkin/weekly
  def weekly_review(conn, %{"assessments" => assessments} = params) do
    did       = conn.assigns.did
    narrative = params["narrative"]

    normalized = Enum.map(assessments, fn {k, v} ->
      {String.to_existing_atom(k), %{score: v["score"] || 50, reflection: v["reflection"]}}
    end) |> Enum.into(%{})

    case CheckIn.weekly_review(did, normalized, narrative) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(result)
      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  # ── PROMPTS ───────────────────────────────────────────────────────────────

  # GET /api/v1/holnn/prompts
  def prompts(conn, _params) do
    json(conn, CheckIn.filter_prompts())
  end

  # ── CURRENT CHECK-IN STATE ────────────────────────────────────────────────

  # GET /api/v1/holnn/checkin/status
  def checkin_status(conn, _params) do
    did = conn.assigns.did
    json(conn, CheckIn.current_state(did))
  end

  # ── TRAINING ─────────────────────────────────────────────────────────────

  # GET /api/v1/holnn/training/status
  def training_status(conn, _params) do
    did   = conn.assigns.did
    count = DataCollector.count_labeled(did)

    json(conn, %{
      label_count:        count,
      min_for_training:   10,
      ready_to_train:     count >= 10,
      progress_pct:       CheckIn.current_state(did).progress_pct,
      next_milestone:     CheckIn.current_state(did).next_milestone,
      training_message:   if(count >= 10,
        do:   "Personal model ready. Training will run automatically.",
        else: "Label #{10 - count} more snapshots to enable personal training."),
    })
  end

  # POST /api/v1/holnn/training/trigger (sovereign tier only)
  def trigger_training(conn, _params) do
    did  = conn.assigns.did
    tier = PRZMA.Deployment.License.did_tier(did)

    if tier == :sovereign do
      case TrainingJob.enqueue(did) do
        {:ok, job}      -> json(conn, %{queued: true, job_id: job.id})
        {:error, reason} -> conn |> put_status(500) |> json(%{error: inspect(reason)})
      end
    else
      conn |> put_status(:forbidden) |> json(%{
        error:   "Manual training trigger requires sovereign tier",
        current: tier,
      })
    end
  end

  # POST /api/v1/holnn/infer (async — triggers background inference job)
  def trigger_inference(conn, _params) do
    did = conn.assigns.did
    PRZMA.HOLNN.InferenceJob.enqueue(did)
    json(conn, %{queued: true, message: "Inference job queued. Result will broadcast to companion channel."})
  end

  # ── PRACTICES ─────────────────────────────────────────────────────────────

  # GET /api/v1/holnn/practices
  def practices(conn, _params) do
    did  = conn.assigns.did
    recs = CompanionIntegration.recommend_practices(did)
    json(conn, %{recommendations: recs, count: length(recs)})
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp format_date(nil), do: nil
  defp format_date(ts) when is_integer(ts) do
    ts
    |> div(1_000_000)
    |> DateTime.from_unix!()
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp parse_filter_states_brief(nil), do: %{}
  defp parse_filter_states_brief(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        Enum.map(map, fn {k, v} ->
          {k, v["state"]}
        end) |> Enum.into(%{})
      _ -> %{}
    end
  end
end

# ── ROUTER SCOPE ──────────────────────────────────────────────────────────────
# Add inside :require_did_auth scope in PRZMAWeb.Router:
#
# scope "/api/v1/holnn", PRZMAWeb do
#   pipe_through [:api, :require_did_auth]
#
#   get    "/state",              HOLNNController, :state
#   get    "/history",            HOLNNController, :history
#   get    "/prompts",            HOLNNController, :prompts
#   get    "/checkin/status",     HOLNNController, :checkin_status
#   post   "/checkin/quick",      HOLNNController, :quick_checkin
#   post   "/checkin/deep",       HOLNNController, :deep_checkin
#   post   "/checkin/weekly",     HOLNNController, :weekly_review
#   get    "/training/status",    HOLNNController, :training_status
#   post   "/training/trigger",   HOLNNController, :trigger_training
#   post   "/infer",              HOLNNController, :trigger_inference
#   get    "/practices",          HOLNNController, :practices
# end
