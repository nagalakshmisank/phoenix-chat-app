# lib/przma_web/controllers/calendar/intelligence_controller.ex
#
# REST endpoints for meeting intelligence features:
# - Pre-brief retrieval
# - During-meeting capture
# - Post-meeting reflection submission
# - Action item management
# - Transcript retrieval

defmodule PRZMAWeb.Calendar.IntelligenceController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Intelligence.{PreBrief, DuringMeeting, PostMeeting}
  alias PRZMA.Calendar.NIF

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── PRE-BRIEF ────────────────────────────────────────────────────────────

  # GET /api/v1/calendar/events/:id/intelligence
  def pre_brief(conn, %{"id" => event_id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"

    case PreBrief.assemble(did, event_id, space) do
      {:ok, brief}  -> json(conn, brief)
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── DURING-MEETING CAPTURE ───────────────────────────────────────────────

  # POST /api/v1/calendar/events/:id/capture/audio
  def capture_audio(conn, %{"id" => event_id} = params) do
    did      = conn.assigns.did
    audio_cas = params["audio_cas"]
    language  = params["language"] || "en"
    circle_did = params["circle_did"]

    if is_nil(audio_cas) do
      conn |> put_status(:bad_request) |> json(%{error: "audio_cas required"})
    else
      case DuringMeeting.capture_audio(did, event_id, audio_cas,
            language: language, circle_did: circle_did) do
        {:ok, :accepted} ->
          conn |> put_status(:accepted) |> json(%{status: "transcribing"})
        {:error, msg} ->
          conn |> put_status(:bad_request) |> json(%{error: msg})
      end
    end
  end

  # POST /api/v1/calendar/events/:id/capture/note
  def capture_note(conn, %{"id" => event_id, "text" => text} = params) do
    did        = conn.assigns.did
    circle_did = params["circle_did"]

    case DuringMeeting.capture_text(did, event_id, text, circle_did: circle_did) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(result)
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/events/:id/capture/marker
  def mark_moment(conn, %{"id" => event_id, "label" => label} = params) do
    did           = conn.assigns.did
    timestamp_secs = params["timestamp_secs"]

    case DuringMeeting.mark_moment(did, event_id, label, timestamp_secs) do
      {:ok, marker} -> json(conn, marker)
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/events/:id/capture/confirm_action
  def confirm_action(conn, %{"id" => event_id, "item" => item} = params) do
    did        = conn.assigns.did
    circle_did = params["circle_did"]

    case DuringMeeting.confirm_action_item(did, event_id, item, circle_did: circle_did) do
      {:ok, task_id} ->
        conn |> put_status(:created) |> json(%{task_id: task_id})
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # ── POST-MEETING ─────────────────────────────────────────────────────────

  # POST /api/v1/calendar/events/:id/reflection
  def submit_reflection(conn, %{"id" => event_id} = params) do
    did = conn.assigns.did

    reflection_params = %{
      "reflection_text" => params["reflection_text"] || "",
      "confirmed_tasks" => params["confirmed_tasks"]   || [],
      "share_summary"   => params["share_summary"]     || false,
      "circle_did"      => params["circle_did"],
      "space"           => params["space"] || "core",
    }

    case PostMeeting.submit_reflection(did, event_id, reflection_params) do
      {:ok, result}  -> json(conn, result)
      {:error, msg}  -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/events/:id/summary
  def meeting_summary(conn, %{"id" => event_id}) do
    did = conn.assigns.did
    case PostMeeting.build_summary(did, event_id) do
      {:ok, summary} -> json(conn, summary)
      {:error, msg}  -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── TRANSCRIPT ───────────────────────────────────────────────────────────

  # GET /api/v1/calendar/events/:id/transcript
  def get_transcript(conn, %{"id" => event_id}) do
    did = conn.assigns.did
    case NIF.get_transcript_for_event(@base_path, did, event_id) do
      {:ok, json}           -> conn |> json(Jason.decode!(json))
      {:error, "not_found"} -> conn |> put_status(:not_found) |> json(%{error: "No transcript"})
      {:error, msg}         -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/events/:id/transcript/text
  def get_transcript_text(conn, %{"id" => event_id}) do
    did = conn.assigns.did
    with {:ok, transcript_json} <- NIF.get_transcript_for_event(@base_path, did, event_id),
         transcript             <- Jason.decode!(transcript_json),
         text_cas               <- transcript["text_cas"],
         {:ok, text}            <- NIF.get_transcript_text(@base_path, did, text_cas) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, Jason.decode!(text))
    else
      _ -> conn |> put_status(:not_found) |> json(%{error: "Transcript text not found"})
    end
  end

  # ── ACTION ITEMS ─────────────────────────────────────────────────────────

  # POST /api/v1/calendar/intelligence/extract
  # Ad-hoc action item extraction from arbitrary text
  def extract_action_items(conn, %{"text" => text}) do
    case NIF.extract_action_items(@base_path, text) do
      {:ok, json}   -> json(conn, %{action_items: Jason.decode!(json)})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end
end
