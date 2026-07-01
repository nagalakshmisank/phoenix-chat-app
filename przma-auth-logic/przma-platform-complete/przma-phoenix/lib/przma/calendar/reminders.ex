# lib/przma/calendar/reminders.ex

defmodule PRZMA.Calendar.Reminders do
  alias PRZMAWeb.Endpoint
  require Logger

  @doc "Schedule Oban reminder jobs for an event's reminders list"
  def schedule_for_event(event, reminder) do
    trigger_at = compute_trigger_at(event["start_at"], reminder)
    Logger.info("Scheduling reminder", event_id: event["id"], trigger_at: trigger_at)

    %{
      reminder_id: reminder["id"] || generate_id(event["id"]),
      did:         event["did"],
      entity_type: "event",
      entity_id:   event["id"],
      delivery:    reminder["delivery"] || ["companion"],
      message:     reminder["message"],
    }
    |> PRZMA.Calendar.Jobs.ReminderDispatcher.new(scheduled_at: trigger_at)
    |> Oban.insert()
  end

  defp compute_trigger_at(start_at_micros, reminder) do
    case reminder["trigger_type"] do
      "relative" ->
        mins = reminder["trigger_mins"] || 10
        start_at_micros
        |> DateTime.from_unix!(:microsecond)
        |> DateTime.add(-mins * 60, :second)
      "absolute" ->
        reminder["trigger_at"]
        |> DateTime.from_unix!(:microsecond)
      _ ->
        DateTime.from_unix!(start_at_micros, :microsecond)
    end
  end

  defp generate_id(entity_id) do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    |> then(&"reminder-#{entity_id}-#{&1}")
  end
end

# ─── OBAN JOBS ────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.ReminderDispatcher do
  use Oban.Worker, queue: :reminders, max_attempts: 3

  alias PRZMAWeb.Endpoint

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    did         = args["did"]
    entity_id   = args["entity_id"]
    delivery    = args["delivery"] || ["companion"]
    message     = args["message"]
    reminder_id = args["reminder_id"]

    summary = %{
      reminder_id: reminder_id,
      entity_type: args["entity_type"],
      entity_id:   entity_id,
      message:     message || "You have an upcoming event",
    }

    Enum.each(delivery, fn channel ->
      case channel do
        "companion" ->
          Endpoint.broadcast("calendar:personal:#{did}", "reminder:due", summary)

        "push" ->
          PRZMA.Push.send(did, %{
            title: "Reminder",
            body:  message || "Upcoming event",
            data:  %{entity_id: entity_id},
          })

        "email" ->
          PRZMA.Mailer.send_reminder(did, summary)

        other ->
          require Logger
          Logger.warning("Unknown reminder delivery channel: #{other}")
      end
    end)

    :ok
  end
end

defmodule PRZMA.Calendar.Jobs.PostMeetingReflection do
  use Oban.Worker, queue: :calendar, max_attempts: 1

  alias PRZMAWeb.Endpoint

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did, "event_id" => event_id}}) do
    Endpoint.broadcast("calendar:personal:#{did}", "companion:prompt", %{
      type:             "post_meeting_reflection",
      event_id:         event_id,
      prompt:           "How did the meeting go? Any key insights or follow-ups?",
      target_vault_domain: "My People",
    })
    :ok
  end

  def enqueue(did, event_id, delay_seconds \\ 300) do
    %{did: did, event_id: event_id}
    |> new(schedule_in: delay_seconds)
    |> Oban.insert()
  end
end

defmodule PRZMA.Calendar.Jobs.TaskCompletionReflection do
  use Oban.Worker, queue: :calendar, max_attempts: 1

  alias PRZMAWeb.Endpoint

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"did" => did, "task_id" => task_id}}) do
    Endpoint.broadcast("calendar:personal:#{did}", "companion:prompt", %{
      type:    "task_completion_reflection",
      task_id: task_id,
      prompt:  "Task complete. Any notes or learnings to record?",
    })
    :ok
  end

  def enqueue(did, task_id) do
    %{did: did, task_id: task_id}
    |> new(schedule_in: 60)
    |> Oban.insert()
  end
end
