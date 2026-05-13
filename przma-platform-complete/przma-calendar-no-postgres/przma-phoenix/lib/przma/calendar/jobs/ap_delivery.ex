# lib/przma/calendar/jobs/ap_delivery.ex
#
# Oban jobs for asynchronous ActivityPub delivery and inbox processing.

defmodule PRZMA.Calendar.Jobs.APDelivery do
  @moduledoc """
  Delivers ActivityPub activities to remote inboxes.
  Uses exponential backoff for failed deliveries.
  """
  use Oban.Worker,
    queue: :federation,
    max_attempts: 5,
    priority: 2

  alias PRZMA.Calendar.Federation.ActivityPub

  @impl Oban.Worker
  def perform(%Oban.Job{
    args: %{
      "inbox_url"    => inbox_url,
      "activity_json" => activity_json,
      "sender_did"   => sender_did,
    },
    attempt: attempt
  }) do
    require Logger

    case ActivityPub.deliver_to_inbox(inbox_url, activity_json, sender_did) do
      {:ok, :delivered} ->
        Logger.debug("AP activity delivered",
          inbox: inbox_url, attempt: attempt)
        :ok

      {:error, {:http_error, code}} when code in [429, 503] ->
        # Rate limited or unavailable — retry with backoff
        {:snooze, backoff_seconds(attempt)}

      {:error, {:http_error, code}} when code in [400, 404, 410] ->
        # Permanent failure — don't retry
        Logger.warning("AP delivery permanent failure",
          inbox: inbox_url, status: code)
        {:discard, "HTTP #{code} — permanent failure"}

      {:error, reason} ->
        Logger.warning("AP delivery failed",
          inbox: inbox_url, reason: inspect(reason), attempt: attempt)
        {:error, reason}
    end
  end

  def enqueue(inbox_url, activity_json, sender_did) do
    %{inbox_url: inbox_url, activity_json: activity_json, sender_did: sender_did}
    |> new()
    |> Oban.insert()
  end

  defp backoff_seconds(attempt) do
    # Exponential backoff: 60, 300, 900, 3600, 7200 seconds
    [60, 300, 900, 3_600, 7_200]
    |> Enum.at(min(attempt - 1, 4))
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.APInboxProcessor do
  @moduledoc """
  Processes inbound ActivityPub activities from the inbox.
  Runs asynchronously to avoid blocking the inbox endpoint.
  """
  use Oban.Worker, queue: :federation, max_attempts: 3

  alias PRZMA.Calendar.Federation.ActivityPub

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "target_did"  => target_did,
    "activity"    => activity,
    "sender_did"  => _sender_did,
  }}) do
    ActivityPub.process_inbound(target_did, activity)
    :ok
  end

  def enqueue(target_did, activity, sender_did) do
    %{target_did: target_did, activity: activity, sender_did: sender_did}
    |> new()
    |> Oban.insert()
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.APPublish do
  @moduledoc """
  Triggered when a user publishes an event to Commons.
  Builds ActivityPub activity and delivers to all followers.
  """
  use Oban.Worker, queue: :federation, max_attempts: 3

  alias PRZMA.Calendar.Federation.ActivityPub

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{
    "did"      => did,
    "event_id" => event_id,
    "space"    => space,
  }}) do
    case ActivityPub.publish_event(did, event_id, space) do
      {:ok, result} ->
        require Logger
        Logger.info("Event published via AP", event_id: event_id, ap_id: result.ap_object_id)
        :ok
      {:error, msg} ->
        {:error, msg}
    end
  end

  def enqueue(did, event_id, space \\ "core") do
    %{did: did, event_id: event_id, space: space}
    |> new()
    |> Oban.insert()
  end
end
