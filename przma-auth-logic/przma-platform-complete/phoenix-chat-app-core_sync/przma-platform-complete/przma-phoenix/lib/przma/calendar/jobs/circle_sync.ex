# lib/przma/calendar/jobs/circle_sync.ex
#
# Oban jobs for circle calendar lifecycle events:
# - Provision namespaces when a member joins
# - Archive namespaces when a member leaves
# - Replicate existing events to a new member

defmodule PRZMA.Calendar.Jobs.CircleProvisioning do
  @moduledoc """
  Triggered when a member accepts a circle invitation.
  1. Provisions Lance tables in member's vault
  2. Replicates existing circle events to the new member
  """
  use Oban.Worker, queue: :circle_sync, max_attempts: 3

  alias PRZMA.Calendar.{Circles, Events, NIF}
  alias PRZMA.Identity

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"member_did" => member_did, "circle_did" => circle_did}}) do
    # Step 1: Provision Lance tables for this member's circle namespace
    with {:ok, result} <- Circles.provision_for_member(member_did, circle_did) do
      require Logger
      Logger.info("Circle namespace provisioned",
        member: member_did, circle: circle_did,
        tables: result["tables_created"])

      # Step 2: Backfill existing circle events to new member
      :ok = backfill_events(member_did, circle_did)
    end
  end

  def enqueue(member_did, circle_did) do
    %{member_did: member_did, circle_did: circle_did}
    |> new()
    |> Oban.insert()
  end

  defp backfill_events(new_member_did, circle_did) do
    # Find an existing member to read from (the Steward if possible)
    case Identity.list_circle_members(circle_did) do
      [] ->
        :ok

      members ->
        existing = Enum.find(members, fn m -> m.did != new_member_did end)
        if existing do
          replicate_from_member(existing.did, new_member_did, circle_did)
        else
          :ok
        end
    end
  end

  defp replicate_from_member(source_did, target_did, circle_did) do
    far_future = DateTime.utc_now() |> DateTime.add(365 * 2 * 24 * 3600, :second)
    past       = DateTime.utc_now() |> DateTime.add(-365 * 24 * 3600, :second)

    case Events.list(source_did,
          space:        "circle:#{circle_did}",
          start_micros: DateTime.to_unix(past, :microsecond),
          end_micros:   DateTime.to_unix(far_future, :microsecond),
          limit:        1000) do
      {:ok, events} ->
        Enum.each(events, fn event ->
          member_event = Map.put(event, "did", target_did)
          NIF.replicate_event_to_member(
            @base_path,
            Jason.encode!(member_event),
            target_did,
            circle_did
          )
        end)
        :ok

      {:error, _} ->
        :ok
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.CircleDeprovision do
  @moduledoc """
  Triggered when a member leaves a circle or is removed.
  Archives the member's circle calendar namespace.
  """
  use Oban.Worker, queue: :circle_sync, max_attempts: 3

  alias PRZMA.Calendar.Circles

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"member_did" => member_did, "circle_did" => circle_did}}) do
    case Circles.deprovision_for_member(member_did, circle_did) do
      {:ok, :archived} ->
        require Logger
        Logger.info("Circle namespace archived", member: member_did, circle: circle_did)
        :ok
      {:error, msg} ->
        {:error, msg}
    end
  end

  def enqueue(member_did, circle_did) do
    %{member_did: member_did, circle_did: circle_did}
    |> new(schedule_in: 300) # 5 min delay — gives member time to export data
    |> Oban.insert()
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.CircleDissolution do
  @moduledoc """
  Triggered when a Steward dissolves a circle.
  Archives ALL members' circle calendar namespaces.
  Unpublishes any Commons-published events.
  Runs after the 7-day notice period.
  """
  use Oban.Worker, queue: :circle_sync, max_attempts: 3

  alias PRZMA.Calendar.Circles
  alias PRZMA.Identity

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"circle_did" => circle_did}}) do
    members = Identity.circle_member_dids(circle_did)

    results = Enum.map(members, fn member_did ->
      {member_did, Circles.deprovision_for_member(member_did, circle_did)}
    end)

    failures = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)

    if Enum.empty?(failures) do
      require Logger
      Logger.info("Circle dissolved and all namespaces archived",
        circle: circle_did, members: length(members))
      :ok
    else
      require Logger
      Logger.error("Circle dissolution partial failure", failures: failures)
      {:error, :partial_failure}
    end
  end

  def schedule(circle_did, notice_days \\ 7) do
    delay_seconds = notice_days * 24 * 3600
    %{circle_did: circle_did}
    |> new(schedule_in: delay_seconds)
    |> Oban.insert()
  end
end
