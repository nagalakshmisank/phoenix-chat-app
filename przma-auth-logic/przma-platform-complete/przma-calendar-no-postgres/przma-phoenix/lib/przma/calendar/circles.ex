# lib/przma/calendar/circles.ex
#
# Circle Calendar context module.
# Orchestrates circle provisioning, event sharing, replication to members,
# poll management, and availability aggregation for group scheduling.

defmodule PRZMA.Calendar.Circles do
  alias PRZMA.Calendar.{Events, NIF, Governance, Polls}
  alias PRZMA.Identity
  alias PRZMAWeb.Endpoint

  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── NAMESPACE PROVISIONING ───────────────────────────────────────────────────

  @doc """
  Provision circle calendar namespace for a single member.
  Called when a member accepts a circle invitation.
  Creates Lance tables in the member's vault under calendar/circles/{circle_did}/.
  """
  def provision_for_member(member_did, circle_did) do
    case NIF.provision_circle_namespace(@base_path, member_did, circle_did) do
      {:ok, json} ->
        result = Jason.decode!(json)
        Logger.info("Circle calendar provisioned",
          member: member_did, circle: circle_did,
          tables_created: result["tables_created"])
        {:ok, result}

      {:error, msg} ->
        Logger.error("Circle calendar provision failed", error: msg)
        {:error, msg}
    end
  end

  @doc """
  Provision circle calendar namespace for ALL current members.
  Called when a new circle is created.
  """
  def provision_for_all_members(circle_did) do
    members = Identity.circle_member_dids(circle_did)
    results = Enum.map(members, fn did ->
      {did, provision_for_member(did, circle_did)}
    end)
    {:ok, results}
  end

  @doc """
  Archive and deprovision circle calendar for a member.
  Called when a member leaves or is removed from a circle.
  """
  def deprovision_for_member(member_did, circle_did) do
    case NIF.archive_circle_namespace(@base_path, member_did, circle_did) do
      :ok           -> {:ok, :archived}
      {:error, msg} -> {:error, msg}
    end
  end

  # ── CIRCLE EVENT SHARING ─────────────────────────────────────────────────────

  @doc """
  Share an event from Core to a Circle.
  1. Permission check — sharer must have Contributor role or above
  2. Copy event record to circle namespace (re-encrypted with circle key in Phase 5)
  3. Replicate to all circle members' vaults
  4. Broadcast invite notification to all members
  """
  def share_event(sharer_did, event_id, circle_did, opts \\ []) do
    permission  = opts[:permission] || "view"
    include_details = opts[:include_details] != false

    with {:ok, role}  <- Identity.get_role(sharer_did, circle_did),
         :ok           <- Governance.assert_permitted(role, :share_to_circle),
         {:ok, event} <- Events.get(sharer_did, event_id, "core") do

      # Build the circle copy
      circle_event = build_circle_copy(event, sharer_did, circle_did, include_details)

      # Replicate to each member's vault
      members  = Identity.circle_member_dids(circle_did)
      results  = replicate_to_members(circle_event, members, circle_did)
      failures = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)

      if failures == [] do
        broadcast_event_shared(circle_event, circle_did, sharer_did)
        Logger.info("Event shared to circle",
          event_id: event_id, circle: circle_did,
          member_count: length(members))
        {:ok, %{circle_event_id: circle_event["id"], member_count: length(members)}}
      else
        Logger.error("Partial replication failure", failures: failures)
        {:error, :replication_partial_failure}
      end
    end
  end

  @doc """
  Retract a shared event from a circle.
  Removes the circle copy from all members' vaults.
  Only the event sharer or a Guardian/Steward can retract.
  """
  def retract_event(requester_did, circle_event_id, circle_did) do
    with {:ok, role} <- Identity.get_role(requester_did, circle_did),
         :ok         <- Governance.assert_permitted(role, :delete_own) do
      members = Identity.circle_member_dids(circle_did)

      Enum.each(members, fn member_did ->
        NIF.remove_event_from_member(@base_path, circle_event_id, member_did, circle_did)
      end)

      broadcast_event_retracted(circle_event_id, circle_did)
      {:ok, :retracted}
    end
  end

  # ── CIRCLE TASK MANAGEMENT ────────────────────────────────────────────────────

  @doc """
  Create a task in the circle namespace.
  Assignees receive the task in their personal task view via broadcast.
  """
  def create_task(creator_did, circle_did, attrs) do
    with {:ok, role} <- Identity.get_role(creator_did, circle_did),
         :ok         <- Governance.assert_permitted(role, :create_task) do

      task = attrs
        |> Map.put("did", creator_did)
        |> Map.put("space", "circle:#{circle_did}")
        |> Map.put("circle_did", circle_did)
        |> Map.put("category", "circle")
        |> Map.put("id", generate_id(creator_did, attrs["title"]))
        |> Map.put("created_at", now_micros())
        |> Map.put("updated_at", now_micros())
        |> Map.put("version", 1)
        |> Map.put("status", "active")
        |> Map.put("progress_pct", 0)
        |> Map.put("embedding", List.duplicate(0.0, 768))

      # Write to creator's circle namespace
      with {:ok, id} <- NIF.create_task(@base_path, creator_did, Jason.encode!(task)) do
        # Replicate task to each assignee's circle namespace
        assignees = attrs["assigned_to"] || []
        Enum.each(assignees, fn assignee_did ->
          if assignee_did != creator_did do
            NIF.create_task(@base_path, assignee_did, Jason.encode!(
              Map.put(task, "did", assignee_did)
            ))
          end
        end)

        # Broadcast to circle channel
        broadcast_task_created(task, circle_did)
        {:ok, id}
      end
    end
  end

  # ── AVAILABILITY AGGREGATION ─────────────────────────────────────────────────

  @doc """
  Aggregate free/busy availability across multiple DIDs for group scheduling.
  Returns merged busy windows — never individual event details.
  Used to find common free slots for scheduling polls.
  """
  def aggregate_availability(requester_did, circle_did, member_dids, start_dt, end_dt) do
    with {:ok, _role} <- Identity.get_role(requester_did, circle_did) do
      start_micros = DateTime.to_unix(start_dt, :microsecond)
      end_micros   = DateTime.to_unix(end_dt, :microsecond)

      # Collect busy windows from each member
      all_busy =
        member_dids
        |> Enum.flat_map(fn did ->
          case PRZMA.Calendar.Availability.freebusy(did, requester_did, start_dt, end_dt) do
            {:ok, slots} -> slots
            {:error, _}  -> []
          end
        end)
        |> Enum.filter(fn s -> s["show_as"] == "busy" end)

      # Merge overlapping busy windows
      merged = merge_busy_windows(all_busy)

      # Find common free slots (30-min intervals)
      free_slots = find_free_slots(merged, start_dt, end_dt, 30)

      {:ok, %{
        busy_windows: merged,
        free_slots:   free_slots,
        member_count: length(member_dids),
      }}
    end
  end

  # ── CIRCLE CALENDAR SUMMARY ───────────────────────────────────────────────────

  @doc "Get a summary of circle calendar state for a member"
  def summary(member_did, circle_did) do
    with {:ok, _role} <- Identity.get_role(member_did, circle_did) do
      case NIF.circle_calendar_summary(@base_path, member_did, circle_did) do
        {:ok, json}   -> {:ok, Jason.decode!(json)}
        {:error, msg} -> {:error, msg}
      end
    end
  end

  # ── PRIVATE HELPERS ──────────────────────────────────────────────────────────

  defp build_circle_copy(event, sharer_did, circle_did, include_details) do
    base = %{
      "id"          => generate_circle_event_id(event["id"], circle_did),
      "did"         => sharer_did,
      "space"       => "circle:#{circle_did}",
      "circle_did"  => circle_did,
      "visibility"  => "circle",
      "created_at"  => now_micros(),
      "updated_at"  => now_micros(),
      "version"     => 1,
    }

    if include_details do
      Map.merge(event, base)
    else
      # Share only time/busy — no title or details
      Map.merge(%{
        "title"       => "Busy",
        "description" => "",
        "category"    => event["category"],
        "start_at"    => event["start_at"],
        "end_at"      => event["end_at"],
        "busy_status" => "busy",
        "attendees"   => [],
        "embedding"   => List.duplicate(0.0, 768),
      }, base)
    end
  end

  defp replicate_to_members(event, member_dids, circle_did) do
    Enum.map(member_dids, fn did ->
      member_event = Map.put(event, "did", did)
      result = NIF.replicate_event_to_member(
        @base_path,
        Jason.encode!(member_event),
        did,
        circle_did
      )
      {did, result}
    end)
  end

  defp broadcast_event_shared(event, circle_did, sharer_did) do
    members = Identity.circle_member_dids(circle_did)
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "event:created", %{
        id:         event["id"],
        title:      event["title"],
        start_at:   event["start_at"],
        end_at:     event["end_at"],
        category:   event["category"],
        shared_by:  sharer_did,
        circle_did: circle_did,
      })
    end)
  end

  defp broadcast_event_retracted(circle_event_id, circle_did) do
    members = Identity.circle_member_dids(circle_did)
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "event:cancelled", %{
        id:         circle_event_id,
        circle_did: circle_did,
      })
    end)
  end

  defp broadcast_task_created(task, circle_did) do
    members = Identity.circle_member_dids(circle_did)
    summary = Map.take(task, ~w(id title due_at priority assigned_to space circle_did))
    Enum.each(members, fn did ->
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "task:created", summary)
    end)
  end

  defp merge_busy_windows(windows) do
    windows
    |> Enum.sort_by(fn w -> w["start_at"] end)
    |> Enum.reduce([], fn window, acc ->
      case acc do
        [] ->
          [window]
        [last | rest] ->
          if window["start_at"] <= last["end_at"] do
            merged = Map.put(last, "end_at", max(last["end_at"], window["end_at"]))
            [merged | rest]
          else
            [window | acc]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp find_free_slots(busy_windows, start_dt, end_dt, duration_mins) do
    start_micros = DateTime.to_unix(start_dt, :microsecond)
    end_micros   = DateTime.to_unix(end_dt, :microsecond)
    step_micros  = duration_mins * 60 * 1_000_000

    start_micros
    |> Stream.iterate(&(&1 + step_micros))
    |> Stream.take_while(&(&1 + step_micros <= end_micros))
    |> Enum.reject(fn slot_start ->
      slot_end = slot_start + step_micros
      Enum.any?(busy_windows, fn busy ->
        slot_start < busy["end_at"] and slot_end > busy["start_at"]
      end)
    end)
    |> Enum.map(fn slot_start ->
      %{
        start_at: slot_start,
        end_at:   slot_start + step_micros,
        show_as:  "free",
      }
    end)
    |> Enum.take(48)  # max 48 slots (24 hours of 30-min slots)
  end

  defp now_micros, do: System.os_time(:microsecond)

  defp generate_id(did, title) do
    :crypto.hash(:sha256, "#{did}-circle-task-#{title}-#{now_micros()}")
    |> Base.encode16(case: :lower)
  end

  defp generate_circle_event_id(event_id, circle_did) do
    :crypto.hash(:sha256, "#{event_id}:#{circle_did}")
    |> Base.encode16(case: :lower)
  end
end
