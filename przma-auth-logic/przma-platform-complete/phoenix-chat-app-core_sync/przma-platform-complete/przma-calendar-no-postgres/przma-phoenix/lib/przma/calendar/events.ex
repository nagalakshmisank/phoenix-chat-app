# lib/przma/calendar/events.ex
#
# Calendar Events context — orchestrates NIF calls, broadcasts,
# permission checking, and Oban job scheduling.

defmodule PRZMA.Calendar.Events do
  alias PRZMA.Calendar.NIF
  alias PRZMA.Calendar.Reminders
  alias PRZMA.Identity
  alias PRZMAWeb.Endpoint

  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── CREATE ──────────────────────────────────────────────────────────────────

  @doc """
  Create a calendar event in the user's sovereign vault.
  Broadcasts to all relevant Phoenix channels after creation.
  Schedules Oban reminder jobs for any attached reminders.
  """
  def create(did, attrs) when is_map(attrs) do
    attrs_with_defaults =
      attrs
      |> Map.put_new("did", did)
      |> Map.put_new("id", generate_id(did, attrs))
      |> Map.put_new("created_by", did)
      |> Map.put_new("organiser_did", did)
      |> Map.put_new("ical_uid", generate_ical_uid(did))
      |> Map.put_new("created_at", now_micros())
      |> Map.put_new("updated_at", now_micros())
      |> Map.put_new("version", 1)
      |> Map.put_new("status", "confirmed")
      |> Map.put_new("visibility", "private")
      |> Map.put_new("busy_status", "busy")
      |> Map.put_new("all_day", false)
      |> Map.put_new("is_recurring", false)
      |> Map.put_new("attendees", [])
      |> Map.put_new("attendee_status", %{})
      |> Map.put_new("has_pre_brief", false)
      |> Map.put_new("has_reflection", false)
      |> Map.put_new("companion_mode", "personal")
      |> Map.put_new("notes_cas", [])
      |> Map.put_new("attachments_cas", [])
      |> Map.put_new("embedding", List.duplicate(0.0, 768))

    event_json = Jason.encode!(attrs_with_defaults)

    with {:ok, id}   <- NIF.create_event(@base_path, did, event_json),
         {:ok, event} <- get(did, id, attrs_with_defaults["space"] || "core") do
      broadcast_event_created(event)
      schedule_reminders(event, attrs["reminders"] || [])
      notify_attendees(event)
      {:ok, event}
    end
  end

  # ── READ ────────────────────────────────────────────────────────────────────

  def get(did, id, space \\ "core") do
    case NIF.get_event(@base_path, did, id, space) do
      {:ok, json}    -> {:ok, Jason.decode!(json)}
      {:error, msg}  -> {:error, msg}
    end
  end

  def list(did, opts \\ []) do
    query = %{
      space:         opts[:space]          || "core",
      start_micros:  opts[:start_micros],
      end_micros:    opts[:end_micros],
      category:      opts[:category],
      status:        opts[:status],
      limit:         opts[:limit]          || 100,
    } |> Map.reject(fn {_, v} -> is_nil(v) end)

    case NIF.list_events(@base_path, did, Jason.encode!(query)) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── UPDATE ──────────────────────────────────────────────────────────────────

  def update(did, id, space, attrs) do
    with {:ok, existing} <- get(did, id, space) do
      updated =
        Map.merge(existing, attrs)
        |> Map.put("updated_at", now_micros())
        |> Map.update("version", 1, &(&1 + 1))

      event_json = Jason.encode!(updated)

      with {:ok, _} <- NIF.update_event(@base_path, did, event_json) do
        broadcast_event_updated(updated)
        {:ok, updated}
      end
    end
  end

  # ── CANCEL ──────────────────────────────────────────────────────────────────

  def cancel(did, id, space \\ "core") do
    with {:ok, json}  <- NIF.cancel_event(@base_path, did, id, space),
         event        <- Jason.decode!(json) do
      broadcast_event_cancelled(event)
      notify_attendees_cancellation(event)
      {:ok, event}
    end
  end

  # ── RSVP ────────────────────────────────────────────────────────────────────

  @doc "Record an RSVP for an event attendee"
  def rsvp(organiser_did, event_id, space, attendee_did, status)
      when status in ~w(accepted declined tentative) do
    with {:ok, event} <- get(organiser_did, event_id, space) do
      attendee_status = Map.put(event["attendee_status"] || %{}, attendee_did, status)
      updated = Map.put(event, "attendee_status", attendee_status)

      with {:ok, _} <- NIF.update_event(@base_path, organiser_did, Jason.encode!(updated)) do
        broadcast_rsvp(event_id, attendee_did, status)
        {:ok, updated}
      end
    end
  end

  # ── SHARE TO CIRCLE ──────────────────────────────────────────────────────────

  @doc """
  Share an event from Core to a Circle.
  Content is copied — the original Core event is unchanged.
  The circle copy is re-encrypted with the circle's derived key.
  """
  def share_to_circle(did, event_id, circle_did, permission) do
    with {:ok, event} <- get(did, event_id, "core"),
         :ok          <- Identity.verify_circle_membership(did, circle_did) do
      circle_event =
        event
        |> Map.put("space", "circle:#{circle_did}")
        |> Map.put("circle_did", circle_did)
        |> Map.put("visibility", "circle")
        |> Map.put("id", generate_circle_id(event["id"], circle_did))
        |> Map.put("created_at", now_micros())
        |> Map.put("updated_at", now_micros())
        |> Map.put("version", 1)

      event_json = Jason.encode!(circle_event)

      with {:ok, id} <- NIF.create_event(@base_path, did, event_json) do
        broadcast_circle_event_created(circle_event, circle_did)
        Logger.info("Event shared to circle", event_id: event_id, circle_did: circle_did)
        {:ok, id}
      end
    end
  end

  # ── SEMANTIC SEARCH ──────────────────────────────────────────────────────────

  def semantic_search(did, space, embedding, top_k \\ 10) do
    embedding_json = Jason.encode!(embedding)
    case NIF.semantic_search_events(@base_path, did, space, embedding_json, top_k) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── ANALYTICS ───────────────────────────────────────────────────────────────

  def analytics(did, query_type, params \\ %{}) do
    case NIF.calendar_analytics(@base_path, did, query_type, Jason.encode!(params)) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── RECURRENCE EXPANSION ────────────────────────────────────────────────────

  def expand_recurring_event(event, range_start_micros, range_end_micros) do
    case event["rrule"] do
      nil   -> {:ok, [event]}
      rrule ->
        start_micros = event["start_at"]
        tz           = event["timezone"] || "UTC"
        case NIF.expand_rrule(rrule, start_micros, tz, range_start_micros, range_end_micros, 500) do
          {:ok, json}   ->
            instances = json
              |> Jason.decode!()
              |> Enum.map(fn ts_micros ->
                duration = event["end_at"] - event["start_at"]
                Map.merge(event, %{
                  "start_at"      => ts_micros,
                  "end_at"        => ts_micros + duration,
                  "recurrence_id" => Integer.to_string(ts_micros),
                })
              end)
            {:ok, instances}
          {:error, msg} -> {:error, msg}
        end
    end
  end

  # ── PRIVATE HELPERS ──────────────────────────────────────────────────────────

  defp now_micros, do: System.os_time(:microsecond)

  defp generate_id(did, attrs) do
    input = "#{did}-#{attrs["title"]}-#{now_micros()}"
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower)
  end

  defp generate_circle_id(event_id, circle_did) do
    :crypto.hash(:sha256, "#{event_id}-#{circle_did}") |> Base.encode16(case: :lower)
  end

  defp generate_ical_uid(did) do
    date  = Date.utc_today() |> Date.to_string() |> String.replace("-", "")
    token = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
    domain = did |> String.split(":") |> List.last()
    "przma-#{date}-#{token}@#{domain}"
  end

  defp broadcast_event_created(event) do
    did   = event["did"]
    space = event["space"]

    # Broadcast to personal channel
    Endpoint.broadcast("calendar:personal:#{did}", "event:created", summarise(event))

    # Broadcast to circle channel if circle event
    if circle_did = event["circle_did"] do
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "event:created", summarise(event))
    end
  end

  defp broadcast_event_updated(event) do
    Endpoint.broadcast("calendar:personal:#{event["did"]}", "event:updated", %{
      id:      event["id"],
      changes: %{status: event["status"], title: event["title"]},
      version: event["version"],
    })
  end

  defp broadcast_event_cancelled(event) do
    Endpoint.broadcast("calendar:personal:#{event["did"]}", "event:cancelled", %{
      id:           event["id"],
      cancelled_by: event["did"],
    })
  end

  defp broadcast_rsvp(event_id, attendee_did, status) do
    # We'd need to look up the organiser's DID here in a real impl
    Logger.info("RSVP broadcast", event_id: event_id, attendee: attendee_did, status: status)
  end

  defp broadcast_circle_event_created(event, circle_did) do
    Endpoint.broadcast("calendar:circle:#{circle_did}:#{event["did"]}", "event:created", summarise(event))
  end

  defp notify_attendees(event) do
    Enum.each(event["attendees"] || [], fn attendee_did ->
      Endpoint.broadcast("calendar:personal:#{attendee_did}", "invite:received", %{
        event_id: event["id"],
        from_did: event["organiser_did"],
        title:    event["title"],
        start_at: event["start_at"],
      })
    end)
  end

  defp notify_attendees_cancellation(event) do
    Enum.each(event["attendees"] || [], fn attendee_did ->
      Endpoint.broadcast("calendar:personal:#{attendee_did}", "event:cancelled", %{
        id:           event["id"],
        cancelled_by: event["organiser_did"],
      })
    end)
  end

  defp schedule_reminders(event, reminders) do
    Enum.each(reminders, fn reminder ->
      Reminders.schedule_for_event(event, reminder)
    end)
  end

  defp summarise(event) do
    Map.take(event, ~w(id title start_at end_at category space circle_did status))
  end
end
