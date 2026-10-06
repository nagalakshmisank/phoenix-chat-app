defmodule PRZMAWeb.Graphql.Resolvers.ChatResolver do
  @moduledoc "Direct messages, inbox/outbox, chat list. Logic lives in Przma.Chat.*."

  import PRZMAWeb.Graphql.Resolvers.Helpers

  alias Przma.Chat.{Messages, Threads}
  alias Przma.Social.Key

  # queries
  def threads(_args, res), do: run(res, fn me -> Threads.list(me.did) end)
  def unread_count(_args, res), do: run(res, fn me -> Threads.unread_total(me.did) end)

  def conversation(%{with_did: peer} = args, res),
    do: run(res, fn me -> Messages.list_thread(me.did, Key.dm_thread(peer), paging(args)) end)

  def inbox(%{thread_key: key} = args, res), do: run(res, fn me -> Messages.inbox(me.did, key, paging(args)) end)
  def outbox(%{thread_key: key} = args, res), do: run(res, fn me -> Messages.outbox(me.did, key, paging(args)) end)

  def message(%{thread_key: key, id: id}, res), do: run(res, fn me -> Messages.get(me.did, key, id) end)

  def blob_url(%{thread_key: key, id: id} = args, res),
    do: run(res, fn me -> Messages.blob_url(me, key, id, args[:expires_in] || 300) end)

  # mutations
  def send_message(%{to_did: to} = args, res), do: run(res, fn me -> Messages.send_dm(me, to, args) end)

  def delete_message(%{thread_key: key, id: id} = args, res),
    do: run(res, fn me -> Messages.delete(me, key, id, args[:for_everyone] == true) end)

  def save_to_vault(%{thread_key: key, id: id}, res), do: run(res, fn me -> Messages.save_to_vault(me, key, id) end)

  def mark_thread_read(%{thread_key: key}, res), do: run(res, fn me -> Threads.mark_read(me.did, key) end)
  def mark_all_read(_args, res), do: run(res, fn me -> Threads.mark_all_read(me.did) end)

  def mute_thread(%{thread_key: key} = args, res) do
    until =
      case args[:minutes] do
        m when is_integer(m) and m > 0 -> System.os_time(:microsecond) + m * 60_000_000
        _ -> nil
      end

    run(res, fn me -> Threads.mute(me.did, key, until) end)
  end

  def unmute_thread(%{thread_key: key}, res), do: run(res, fn me -> Threads.unmute(me.did, key) end)
end
