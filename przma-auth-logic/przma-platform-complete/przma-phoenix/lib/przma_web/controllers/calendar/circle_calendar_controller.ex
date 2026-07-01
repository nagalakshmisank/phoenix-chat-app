# lib/przma_web/controllers/calendar/circle_calendar_controller.ex
#
# REST endpoints for circle calendar operations.
# All endpoints require DID auth and circle membership.

defmodule PRZMAWeb.Calendar.CircleCalendarController do
  use PRZMAWeb, :controller

  alias PRZMA.Calendar.{Circles, Events, Tasks, Polls}
  alias PRZMA.Calendar.Governance
  alias PRZMA.Identity

  # ── CIRCLE SUMMARY ───────────────────────────────────────────────────────────

  # GET /api/v1/calendar/circles/:circle_did/summary
  def summary(conn, %{"circle_did" => circle_did}) do
    did = conn.assigns.did
    case Circles.summary(did, circle_did) do
      {:ok, summary} -> json(conn, summary)
      {:error, msg}  -> conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  # ── EVENTS ───────────────────────────────────────────────────────────────────

  # GET /api/v1/calendar/circles/:circle_did/events
  def list_events(conn, %{"circle_did" => circle_did} = params) do
    did  = conn.assigns.did
    role = conn.assigns[:circle_role] || "participant"

    opts = [
      space:        "circle:#{circle_did}",
      start_micros: parse_micros(params["start"]),
      end_micros:   parse_micros(params["end"]),
      category:     params["category"],
      status:       params["status"],
      limit:        parse_int(params["limit"], 100),
    ]

    case Events.list(did, opts) do
      {:ok, events} -> json(conn, %{events: events, circle_did: circle_did, role: role})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/circles/:circle_did/events
  def create_event(conn, %{"circle_did" => circle_did} = params) do
    did = conn.assigns.did
    with {:ok, role} <- Identity.get_role(did, circle_did),
         :ok         <- Governance.assert_permitted(role, :create_content) do
      attrs = params
        |> Map.put("space", "circle:#{circle_did}")
        |> Map.put("circle_did", circle_did)
        |> Map.put("visibility", "circle")
      case Events.create(did, attrs) do
        {:ok, event} ->
          conn |> put_status(:created) |> json(%{id: event["id"], circle_did: circle_did})
        {:error, msg} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
      end
    else
      {:error, :permission_denied} ->
        conn |> put_status(:forbidden) |> json(%{error: "Insufficient role"})
      {:error, msg} ->
        conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  # DELETE /api/v1/calendar/circles/:circle_did/events/:id
  def delete_event(conn, %{"circle_did" => circle_did, "id" => event_id}) do
    did = conn.assigns.did
    with {:ok, role} <- Identity.get_role(did, circle_did) do
      space = "circle:#{circle_did}"
      # Guardian+ can delete any; others only their own
      cond do
        Governance.can_delete_any?(role) ->
          case Events.cancel(did, event_id, space) do
            {:ok, _}      -> json(conn, %{id: event_id, status: "cancelled"})
            {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
          end
        Governance.can_delete_own?(role) ->
          # Verify ownership before cancelling
          case Events.get(did, event_id, space) do
            {:ok, event} when event["organiser_did"] == did ->
              Events.cancel(did, event_id, space)
              json(conn, %{id: event_id, status: "cancelled"})
            {:ok, _} ->
              conn |> put_status(:forbidden) |> json(%{error: "Can only delete own events"})
            {:error, msg} ->
              conn |> put_status(:not_found) |> json(%{error: msg})
          end
        true ->
          conn |> put_status(:forbidden) |> json(%{error: "Insufficient role"})
      end
    end
  end

  # ── TASKS ────────────────────────────────────────────────────────────────────

  # POST /api/v1/calendar/circles/:circle_did/tasks
  def create_task(conn, %{"circle_did" => circle_did} = params) do
    did = conn.assigns.did
    case Circles.create_task(did, circle_did, params) do
      {:ok, id}     -> conn |> put_status(:created) |> json(%{id: id})
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # ── AVAILABILITY AGGREGATION ─────────────────────────────────────────────────

  # POST /api/v1/calendar/circles/:circle_did/availability/aggregate
  def aggregate_availability(conn, %{"circle_did" => circle_did} = params) do
    did        = conn.assigns.did
    member_dids = params["member_dids"] || Identity.circle_member_dids(circle_did)
    start_dt   = parse_datetime(params["start"])
    end_dt     = parse_datetime(params["end"])

    case Circles.aggregate_availability(did, circle_did, member_dids, start_dt, end_dt) do
      {:ok, result}  -> json(conn, result)
      {:error, msg}  -> conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  # ── POLLS ────────────────────────────────────────────────────────────────────

  # GET /api/v1/calendar/circles/:circle_did/polls
  def list_polls(conn, %{"circle_did" => circle_did}) do
    did = conn.assigns.did
    case Polls.list(circle_did, did) do
      {:ok, polls}  -> json(conn, %{polls: polls})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/circles/:circle_did/polls
  def create_poll(conn, %{"circle_did" => circle_did} = params) do
    did = conn.assigns.did
    case Polls.create(did, circle_did, params) do
      {:ok, poll}   -> conn |> put_status(:created) |> json(poll)
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/circles/:circle_did/polls/:id/vote
  def vote_poll(conn, %{"circle_did" => circle_did, "id" => poll_id} = params) do
    did        = conn.assigns.did
    option_ids = params["option_ids"] || []
    case Polls.vote(poll_id, circle_did, did, option_ids) do
      {:ok, poll}   -> json(conn, poll)
      {:error, msg} -> conn |> put_status(:conflict) |> json(%{error: msg})
    end
  end

  # POST /api/v1/calendar/circles/:circle_did/polls/:id/resolve
  def resolve_poll(conn, %{"circle_did" => circle_did, "id" => poll_id} = params) do
    did    = conn.assigns.did
    winner = params["winning_option"]
    case Polls.resolve(poll_id, circle_did, winner, did) do
      {:ok, poll}   -> json(conn, poll)
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  # GET /api/v1/calendar/circles/:circle_did/polls/:id/tally
  def poll_tally(conn, %{"circle_did" => circle_did, "id" => poll_id}) do
    did = conn.assigns.did
    case Polls.tally(poll_id, circle_did, did) do
      {:ok, tally}  -> json(conn, tally)
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # ── PRIVATE HELPERS ──────────────────────────────────────────────────────────

  defp parse_micros(nil), do: nil
  defp parse_micros(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _            -> nil
    end
  end

  defp parse_int(nil, default), do: default
  defp parse_int(str, _),       do: String.to_integer(str)

  defp parse_datetime(nil), do: DateTime.utc_now()
  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _            -> DateTime.utc_now()
    end
  end
end
