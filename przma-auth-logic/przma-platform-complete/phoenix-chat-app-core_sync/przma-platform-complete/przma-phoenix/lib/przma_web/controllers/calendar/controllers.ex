# lib/przma_web/controllers/calendar/task_controller.ex

defmodule PRZMAWeb.Calendar.TaskController do
  use PRZMAWeb, :controller
  alias PRZMA.Calendar.Tasks

  def index(conn, params) do
    did  = conn.assigns.did
    opts = [
      space:       params["space"] || "core",
      status:      params["status"],
      assigned_to: params["assigned_to"],
      limit:       String.to_integer(params["limit"] || "100"),
    ]
    case Tasks.list(did, opts) do
      {:ok, tasks}  -> json(conn, %{tasks: tasks})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  def create(conn, params) do
    did = conn.assigns.did
    case Tasks.create(did, params) do
      {:ok, id}     -> conn |> put_status(:created) |> json(%{id: id})
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  def complete(conn, %{"id" => id} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"
    case Tasks.complete(did, id, space) do
      {:ok, task}   -> json(conn, task)
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  def assign(conn, %{"id" => id, "assignee_did" => assignee_did} = params) do
    did        = conn.assigns.did
    space      = params["space"] || "core"
    circle_did = params["circle_did"]
    case Tasks.assign(did, id, space, assignee_did, circle_did) do
      {:ok, result} -> json(conn, result)
      {:error, msg} -> conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  def block(conn, %{"id" => id, "reason" => reason} = params) do
    did   = conn.assigns.did
    space = params["space"] || "core"
    case Tasks.block(did, id, space, reason) do
      :ok           -> json(conn, %{id: id, status: "blocked"})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMAWeb.Calendar.AvailabilityController do
  use PRZMAWeb, :controller
  alias PRZMA.Calendar.Availability

  def index(conn, params) do
    did   = conn.assigns.did
    start = parse_dt(params["start"])
    finish = parse_dt(params["end"])
    case Availability.list_windows(did, start, finish) do
      {:ok, windows} -> json(conn, %{windows: windows})
      {:error, msg}  -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  def update(conn, %{"windows" => windows}) do
    did = conn.assigns.did
    case Availability.set_windows(did, windows) do
      :ok           -> json(conn, %{updated: true})
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  def freebusy(conn, %{"did" => target_did} = params) do
    requester_did = conn.assigns.did
    start  = parse_dt(params["start"])
    finish = parse_dt(params["end"])
    case Availability.freebusy(target_did, requester_did, start, finish) do
      {:ok, slots}  -> json(conn, %{freebusy: slots})
      {:error, msg} -> conn |> put_status(:forbidden) |> json(%{error: msg})
    end
  end

  defp parse_dt(nil), do: DateTime.utc_now()
  defp parse_dt(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _            -> DateTime.utc_now()
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMAWeb.Calendar.BookingController do
  use PRZMAWeb, :controller
  alias PRZMA.Calendar.Availability

  # Public — no auth required
  def show(conn, %{"id" => link_id}) do
    case Availability.get_booking_link(link_id) do
      {:ok, link}   -> json(conn, link)
      {:error, msg} -> conn |> put_status(:not_found) |> json(%{error: msg})
    end
  end

  # Public — no auth required
  def book(conn, %{"id" => link_id} = params) do
    slot_start   = params["slot_start"]
    booker_name  = params["booker_name"]
    booker_email = params["booker_email"]
    answers      = params["answers"] || []

    case Availability.book_slot(link_id, slot_start, booker_name, booker_email, answers) do
      {:ok, event}  ->
        conn |> put_status(:created) |> json(%{
          event_id:    event["id"],
          start_at:    event["start_at"],
          message:     "Booking confirmed",
        })
      {:error, msg} ->
        conn |> put_status(:conflict) |> json(%{error: msg})
    end
  end

  def create(conn, params) do
    did = conn.assigns.did
    case Availability.create_booking_link(did, params) do
      {:ok, link}   ->
        conn |> put_status(:created) |> json(%{
          id:          link["id"],
          booking_url: "https://#{did_domain(did)}/book/#{link["id"]}",
        })
      {:error, msg} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  defp did_domain(did) do
    did |> String.split(":") |> Enum.drop(2) |> Enum.join(".")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMAWeb.Calendar.PollController do
  use PRZMAWeb, :controller
  alias PRZMA.Calendar.Polls

  def index(conn, %{"circle_did" => circle_did}) do
    case Polls.list(circle_did) do
      {:ok, polls}  -> json(conn, %{polls: polls})
      {:error, msg} -> conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  def create(conn, %{"circle_did" => circle_did} = params) do
    did = conn.assigns.did
    case Polls.create(did, circle_did, params) do
      {:ok, poll}   -> conn |> put_status(:created) |> json(poll)
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end

  def vote(conn, %{"id" => poll_id, "circle_did" => circle_did, "option_ids" => option_ids}) do
    voter_did = conn.assigns.did
    case Polls.vote(poll_id, circle_did, voter_did, option_ids) do
      {:ok, poll}   -> json(conn, poll)
      {:error, msg} -> conn |> put_status(:conflict) |> json(%{error: msg})
    end
  end

  def resolve(conn, %{"id" => poll_id, "circle_did" => circle_did, "winning_option" => opt}) do
    case Polls.resolve(poll_id, circle_did, opt) do
      {:ok, poll}   -> json(conn, poll)
      {:error, msg} -> conn |> put_status(:unprocessable_entity) |> json(%{error: msg})
    end
  end
end
