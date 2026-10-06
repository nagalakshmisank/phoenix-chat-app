defmodule Przma.Chat.Threads do
  @moduledoc """
  The chat list. One document per conversation in the user's own database:

      chat:private:threads:{thread_key}

  thread_key is the other person (direct message), "c_<circle_id>"
  (circle) or "sys" (notifications). The document carries what a chat
  list row needs — last message preview, unread count, mute state — so
  the list and the unread badges never scan the inbox.

  Read state is WhatsApp-style: opening a chat stores `last_read_id`;
  an item is unread when its id is greater than that. No per-message
  write is needed.
  """

  alias Przma.Social.Store

  @ns "chat"
  @table "threads"

  def get(did, thread_key), do: Store.get(did, @ns, @table, thread_key)

  @doc "All conversations, most recent first."
  def list(did) do
    with {:ok, rows} <- Store.list(did, @ns, @table, limit: 1000) do
      {:ok, rows |> Enum.map(&view/1) |> Enum.sort_by(&(&1["last_at"] || 0), :desc)}
    end
  end

  @doc """
  Records a new item on a conversation. `info` identifies the thread
  (kind, peer_did, circle_id, title); `unread: true` also adds 1 to the
  unread counter atomically.
  """
  def touch(did, thread_key, info, item, opts \\ []) do
    fields =
      info
      |> Map.merge(%{
        "thread_key" => thread_key,
        "last_msg_id" => item["msg_id"],
        "last_preview" => preview(item),
        "last_actor_did" => item["actor_did"],
        "last_category" => item["category"],
        "last_at" => item["sent_at"]
      })
      |> maybe_inc(Keyword.get(opts, :unread, false))

    Store.put(did, @ns, @table, thread_key, fields)
  end

  @doc "Marks everything in the conversation as read."
  def mark_read(did, thread_key) do
    with {:ok, thread} <- get(did, thread_key),
         :ok <-
           Store.put(did, @ns, @table, thread_key, %{
             "unread_count" => 0,
             "last_read_id" => thread["last_msg_id"]
           }) do
      get_view(did, thread_key)
    end
  end

  def mark_all_read(did) do
    with {:ok, threads} <- list(did) do
      threads
      |> Enum.filter(&((&1["unread_count"] || 0) > 0))
      |> Enum.each(&mark_read(did, &1["thread_key"]))

      :ok
    end
  end

  @doc "Mutes a conversation. `until` is microseconds since epoch, or nil for 'until I unmute'."
  def mute(did, thread_key, until \\ nil) do
    with {:ok, _} <- get(did, thread_key),
         :ok <- Store.put(did, @ns, @table, thread_key, %{"muted" => true, "muted_until" => until}) do
      get_view(did, thread_key)
    end
  end

  def unmute(did, thread_key) do
    with {:ok, _} <- get(did, thread_key),
         :ok <- Store.put(did, @ns, @table, thread_key, %{"muted" => false, "muted_until" => nil}) do
      get_view(did, thread_key)
    end
  end

  @doc "Total unread across all conversations (the app badge)."
  def unread_total(did) do
    with {:ok, threads} <- list(did) do
      {:ok, Enum.reduce(threads, 0, fn t, acc -> acc + (t["unread_count"] || 0) end)}
    end
  end

  @doc "True while a mute is in force."
  def muted?(%{"muted" => true, "muted_until" => until}) when is_integer(until),
    do: until > System.os_time(:microsecond)

  def muted?(%{"muted" => true}), do: true
  def muted?(_), do: false

  # ── private ──────────────────────────────────────────────────────────

  defp get_view(did, thread_key) do
    with {:ok, thread} <- get(did, thread_key), do: {:ok, view(thread)}
  end

  defp view(thread) do
    thread
    |> Map.put("unread_count", thread["unread_count"] || 0)
    |> Map.put("muted", muted?(thread))
  end

  defp maybe_inc(fields, true), do: Map.put(fields, "$inc", %{"unread_count" => 1})
  defp maybe_inc(fields, _), do: fields

  defp preview(%{"content" => content}) when is_binary(content) and content != "", do: String.slice(content, 0, 80)
  defp preview(%{"object_name" => name}) when is_binary(name), do: "File: " <> name
  defp preview(%{"text" => text}) when is_binary(text), do: String.slice(text, 0, 80)
  defp preview(_), do: ""
end
