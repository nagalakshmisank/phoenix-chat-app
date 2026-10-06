defmodule Przma.Circle.Pins do
  @moduledoc """
  Pinned circle messages, stored with the circle in the owner's database:

      circle:private:pins:{circle_id}_{msg_id}
  """

  alias Przma.Circle.{Members, Permissions}
  alias Przma.Notify.Publisher
  alias Przma.Social.{Key, Store}

  def pin(%{did: did}, circle_id, msg_id) do
    with :ok <- valid(msg_id),
         {:ok, %{owner: owner}} <- Members.authorize(did, circle_id, "pin_message"),
         :ok <-
           Store.put(owner, "circle", "pins", record(circle_id, msg_id), %{
             "circle_id" => circle_id,
             "message_id" => msg_id,
             "pinned_by" => did,
             "pinned_at" => System.os_time(:microsecond),
             "status" => "pinned"
           }) do
      Publisher.circle_event(circle_id, "message_pinned", %{message_id: msg_id, actor_did: did})
      {:ok, %{"circle_id" => circle_id, "message_id" => msg_id, "pinned_by" => did, "status" => "pinned"}}
    end
  end

  def unpin(%{did: did}, circle_id, msg_id) do
    with :ok <- valid(msg_id),
         {:ok, %{owner: owner, role: role}} <- Members.context(did, circle_id),
         {:ok, %{"status" => "pinned", "pinned_by" => pinned_by}} <-
           Store.get(owner, "circle", "pins", record(circle_id, msg_id)),
         :ok <- if(Permissions.can_unpin?(role, did, pinned_by), do: :ok, else: {:error, :forbidden}),
         :ok <- Store.put(owner, "circle", "pins", record(circle_id, msg_id), %{"status" => "unpinned"}) do
      Publisher.circle_event(circle_id, "message_unpinned", %{message_id: msg_id, actor_did: did})
      {:ok, %{"circle_id" => circle_id, "message_id" => msg_id, "status" => "unpinned"}}
    else
      {:ok, _} -> {:error, :not_found}
      err -> err
    end
  end

  def list(did, circle_id) do
    with {:ok, %{owner: owner}} <- Members.context(did, circle_id),
         {:ok, rows} <- Store.list(owner, "circle", "pins", prefix: circle_id <> "_", limit: 1000) do
      {:ok, Enum.filter(rows, &(&1["status"] == "pinned"))}
    end
  end

  defp record(circle_id, msg_id), do: circle_id <> "_" <> msg_id

  defp valid(msg_id), do: if(Key.valid_id?(msg_id), do: :ok, else: {:error, :not_found})
end
