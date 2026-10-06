defmodule Przma.Circle.Messages do
  @moduledoc """
  Circle (group) messages. They are NOT a separate table: a circle
  message is an ordinary outbox item for the sender and an inbox item
  for every other active member, all in the thread "c_<circle_id>".
  So a member reads a circle exactly like a direct conversation, from
  their own database.
  """

  alias Przma.Chat.{Delivery, Messages, Threads}
  alias Przma.Circle.{Members, Permissions}
  alias Przma.Notify.Publisher
  alias Przma.Social.Key

  def send(%{did: did}, circle_id, attrs) do
    with {:ok, %{owner: owner, circle: circle}} <- Members.authorize(did, circle_id, "send_message"),
         {:ok, item} <- Messages.build_item(did, "Message", attrs, %{"circle_id" => circle_id}),
         {:ok, members} <- Members.list(owner, circle_id) do
      item = if item["category"] == "message", do: Map.put(item, "category", "circle_message"), else: item
      thread = Key.circle_thread(circle_id)
      info = %{"kind" => "circle", "circle_id" => circle_id, "title" => circle["name"]}
      recipients = for m <- members, m["member_did"] != did, do: m["member_did"]

      with :ok <- Messages.write_outbox(did, thread, item, []),
           :ok <- Threads.touch(did, thread, info, item),
           {:ok, _report} <- Delivery.deliver(recipients, item, thread: thread, thread_info: info) do
        message = Messages.view(Map.merge(item, %{"thread_key" => thread, "status" => "sent"}), "out", nil)
        Publisher.circle_event(circle_id, "new_message", %{message_id: item["msg_id"], actor_did: did})
        {:ok, message}
      end
    end
  end

  @doc "The circle's messages as the caller has them (newest first). Options: :before, :limit."
  def list(did, circle_id, opts \\ []) do
    with {:ok, _ctx} <- Members.context(did, circle_id) do
      Messages.list_thread(did, Key.circle_thread(circle_id), opts)
    end
  end

  @doc """
  Deletes a circle message for everyone. Allowed for the sender, and for
  owner/admin on anyone's message. The sender is known from the caller's
  own copy (outbox = I sent it; inbox copy names the sender).
  """
  def delete(%{did: did}, circle_id, msg_id) do
    thread = Key.circle_thread(circle_id)
    record = Key.record(thread, msg_id)

    with {:ok, %{owner: owner, role: role}} <- Members.context(did, circle_id),
         {:ok, box, doc} <- Messages.find(did, thread, msg_id),
         sender = if(box == "outbox", do: did, else: doc["actor_did"]),
         :ok <- allowed(sender == did or Permissions.can?("delete_edit_others_messages", role)),
         {:ok, members} <- Members.list(owner, circle_id) do
      Delivery.retract(sender, "outbox", record)
      Enum.each(members, &Delivery.retract(&1["member_did"], "inbox", record))

      Publisher.circle_event(circle_id, "message_deleted", %{message_id: msg_id, actor_did: did})
      {:ok, %{"id" => msg_id, "thread_key" => thread, "status" => "deleted"}}
    end
  end

  @doc "Live 'is typing' signal to the other members. Nothing is stored."
  def typing(%{did: did}, circle_id) do
    with {:ok, _ctx} <- Members.context(did, circle_id) do
      Publisher.circle_event(circle_id, "typing", %{actor_did: did})
      {:ok, true}
    end
  end

  defp allowed(true), do: :ok
  defp allowed(false), do: {:error, :forbidden}
end
