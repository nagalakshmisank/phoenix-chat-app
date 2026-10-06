defmodule Przma.Notify.Notifications do
  @moduledoc """
  Notifications that are not chat messages: new follower, circle join
  request, added to / removed from a circle, role changed, and so on.

  They are ordinary inbox items in the reserved thread "sys", so they are
  stored, counted and pushed by the same Delivery path as messages:

      chat:private:inbox:sys-{msg_id}
      chat:private:threads:sys          (unread counter)

  Message notifications (direct, circle, file) need no extra record: the
  message in the inbox plus the thread's unread counter IS the notification.
  """

  alias Przma.Chat.{Delivery, Messages, Threads}
  alias Przma.Social.Key

  @thread "sys"

  @doc """
  Sends one notification to each recipient.
    activity_type  e.g. "Follow", "JoinRequest", "CircleAdded"
    category       "follow" | "circle"
    text           ready-to-show sentence
    extra          more item fields (circle_id, subject_did, ...)
    opts           extra Delivery options (:pointer)
  """
  def send(recipients, actor_did, activity_type, category, text, extra \\ %{}, opts \\ []) do
    item =
      Map.merge(
        %{
          "msg_id" => Key.message_id(),
          "activity_type" => activity_type,
          "category" => category,
          "actor_did" => actor_did,
          "text" => text,
          "sent_at" => System.os_time(:microsecond)
        },
        extra
      )

    Delivery.deliver(
      recipients,
      item,
      [thread: @thread, thread_info: %{"kind" => "system", "title" => "Notifications"}] ++ opts
    )
  end

  @doc "The caller's notifications, newest first. Options: :before, :limit, :category, :unread_only."
  def list(did, opts \\ []) do
    with {:ok, items} <- Messages.inbox(did, @thread, opts) do
      {:ok,
       items
       |> filter(:category, opts[:category])
       |> filter(:unread_only, opts[:unread_only])}
    end
  end

  def mark_read(did), do: Threads.mark_read(did, @thread)

  defp filter(items, :category, category) when is_binary(category),
    do: Enum.filter(items, &(&1["category"] == category))

  defp filter(items, :unread_only, true), do: Enum.reject(items, & &1["read"])
  defp filter(items, _, _), do: items
end
