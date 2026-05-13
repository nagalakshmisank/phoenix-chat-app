# lib/przma_web/controllers/calendar/event_controller.ex

defmodule PRZMAWeb.Calendar.EventController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.Events

  # ── INDEX — GET /api/v1/calendar/events ────────────────────────────────────

  def index(conn, params) do
    did = conn.assigns.did

    opts = [
      space:         params["space"]    || "core",
      start_micros:  parse_micros(params["start"]),
      end_micros:    parse_micros(params["end"]),
      category:      params["category"],
      status:        params["status"],
      limit:         parse_int(params["limit"], 100),
    ]

    case Events.list(did, opts) do
      {:ok, events} ->
        conn
        |> put_status(:ok)
        |> json(%{events: events, count: length(events)})

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end

  # ── SHOW — GET /api/v1/calendar/events/:id ─────────────────────────────────

  def show(conn, %{"id" => id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"

    case Events.get(did, id, space) do
      {:ok, event}  -> json(conn, event)
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── CREATE — POST /api/v1/calendar/events ──────────────────────────────────

  def create(conn, params) do
    did = conn.assigns.did

    case Events.create(did, params) do
      {:ok, event} ->
        conn
        |> put_status(:created)
        |> json(%{
          id:           event["id"],
          cas_hash:     event["id"],
          ical_uid:     event["ical_uid"],
          status:       event["status"],
          version:      event["version"],
          created_at:   event["created_at"],
        })

      {:error, msg} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # ── UPDATE — PUT /api/v1/calendar/events/:id ───────────────────────────────

  def update(conn, %{"id" => id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"

    case Events.update(did, id, space, Map.drop(params, ["id", "space"])) do
      {:ok, event}  -> json(conn, event)
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # ── DELETE (CANCEL) — DELETE /api/v1/calendar/events/:id ──────────────────

  def delete(conn, %{"id" => id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"

    case Events.cancel(did, id, space) do
      {:ok, event}  -> json(conn, %{id: event["id"], status: "cancelled"})
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── RSVP — POST /api/v1/calendar/events/:id/rsvp ──────────────────────────

  def rsvp(conn, %{"id" => id, "status" => status} = params) do
    attendee_did  = conn.assigns.did
    organiser_did = params["organiser_did"] || conn.assigns.did
    space         = params["space"] || "core"

    case Events.rsvp(organiser_did, id, space, attendee_did, status) do
      {:ok, event}  -> json(conn, %{event_id: id, status: status})
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # ── SHARE — POST /api/v1/calendar/events/:id/share ────────────────────────

  def share(conn, %{"id" => id, "circle_did" => circle_did} = params) do
    did        = conn.assigns.did
    permission = params["permission"] || "view"

    case Events.share_to_circle(did, id, circle_did, permission) do
      {:ok, circle_event_id} ->
        conn
        |> put_status(:created)
        |> json(%{circle_event_id: circle_event_id, circle_did: circle_did})

      {:error, msg} ->
        conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  # ── INTELLIGENCE — GET /api/v1/calendar/events/:id/intelligence ────────────

  def intelligence(conn, %{"id" => id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"

    with {:ok, event} <- Events.get(did, id, space) do
      pre_brief = build_pre_brief(did, event)
      json(conn, %{event_id: id, pre_brief: pre_brief})
    else
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── SEARCH — POST /api/v1/calendar/events/search ──────────────────────────

  def search(conn, %{"query" => _query} = params) do
    did       = conn.assigns.did
    space     = params["space"] || "core"
    embedding = params["embedding"] || List.duplicate(0.0, 768)
    top_k     = params["top_k"] || 10

    case Events.semantic_search(did, space, embedding, top_k) do
      {:ok, results} -> json(conn, %{results: results})
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # ── ANALYTICS — POST /api/v1/calendar/events/analytics ────────────────────

  def analytics(conn, %{"query_type" => query_type} = params) do
    did = conn.assigns.did

    case Events.analytics(did, query_type, Map.drop(params, ["query_type"])) do
      {:ok, result}  -> json(conn, result)
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # ── PRIVATE HELPERS ────────────────────────────────────────────────────────

  defp parse_micros(nil), do: nil
  defp parse_micros(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _}  -> DateTime.to_unix(dt, :microsecond)
      _             -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(str, _default), do: String.to_integer(str)

  defp build_pre_brief(did, event) do
    attendees = event["attendees"] || []
    %{
      attendee_context: Enum.map(attendees, fn a_did ->
        %{
          did:                  a_did,
          last_interaction:     nil,    # populated by Arc Engine in Phase 6
          open_tasks:           [],     # populated from tasks store
          recent_shared_events: 0,
        }
      end),
      relevant_vault_items: [],          # populated by companion in Phase 6
      suggested_agenda:     [],
      open_action_items:    [],
    }
  end
end
