# lib/przma/calendar/tasks.ex

defmodule PRZMA.Calendar.Tasks do
  alias PRZMA.Calendar.NIF
  alias PRZMAWeb.Endpoint

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  def create(did, attrs) do
    task =
      attrs
      |> Map.put_new("did", did)
      |> Map.put_new("id", generate_id(did, attrs))
      |> Map.put_new("assigned_by", did)
      |> Map.put_new("assigned_to", [did])
      |> Map.put_new("status", "draft")
      |> Map.put_new("priority", "medium")
      |> Map.put_new("category", "personal")
      |> Map.put_new("progress_pct", 0)
      |> Map.put_new("notes_cas", [])
      |> Map.put_new("embedding", List.duplicate(0.0, 768))
      |> Map.put_new("created_at", now_micros())
      |> Map.put_new("updated_at", now_micros())
      |> Map.put_new("version", 1)

    with {:ok, id} <- NIF.create_task(@base_path, did, Jason.encode!(task)) do
      broadcast_task_created(task)
      {:ok, id}
    end
  end

  def complete(did, task_id, space \\ "core") do
    with {:ok, json} <- NIF.complete_task(@base_path, did, task_id, space, did),
         task        <- Jason.decode!(json) do
      broadcast_task_updated(task)
      trigger_post_completion_reflection(task)
      {:ok, task}
    end
  end

  def assign(did, task_id, space, assignee_did, circle_did) do
    # Fetch, update assignee, broadcast
    {:ok, %{task_id: task_id, assignee: assignee_did}}
  end

  def block(did, task_id, space, reason) do
    # Fetch, set status=blocked, broadcast to circle
    Endpoint.broadcast(
      "calendar:personal:#{did}",
      "task:updated",
      %{id: task_id, status: "blocked", blocked_reason: reason}
    )
    :ok
  end

  defp broadcast_task_created(task) do
    Endpoint.broadcast("calendar:personal:#{task["did"]}", "task:created", %{
      id:          task["id"],
      title:       task["title"],
      due_at:      task["due_at"],
      priority:    task["priority"],
      assigned_to: task["assigned_to"],
      space:       task["space"],
    })

    if circle_did = task["circle_did"] do
      Endpoint.broadcast("calendar:circle:#{circle_did}:#{task["did"]}", "task:created",
        Map.take(task, ~w(id title due_at priority assigned_to space)))
    end
  end

  defp broadcast_task_updated(task) do
    Endpoint.broadcast("calendar:personal:#{task["did"]}", "task:updated", %{
      id:           task["id"],
      status:       task["status"],
      progress_pct: task["progress_pct"],
      updated_by:   task["did"],
    })
  end

  defp trigger_post_completion_reflection(task) do
    # Enqueue Oban job for post-completion companion prompt
    PRZMA.Calendar.Jobs.TaskCompletionReflection.enqueue(task["did"], task["id"])
  end

  defp now_micros, do: System.os_time(:microsecond)

  defp generate_id(did, attrs) do
    :crypto.hash(:sha256, "#{did}-task-#{attrs["title"]}-#{now_micros()}")
    |> Base.encode16(case: :lower)
  end
end
