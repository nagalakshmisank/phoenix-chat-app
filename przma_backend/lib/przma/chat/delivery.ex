defmodule Przma.Chat.Delivery do
  @moduledoc """
  Puts an item into other users' inboxes. This is the ONLY module that
  writes into a recipient's database, and it writes exactly three things
  there, all part of "you received something":

    1. the inbox item            chat:private:inbox:{thread}-{msg_id}
    2. the chat-list counter     chat:private:threads:{thread}   (unread +1)
    3. for circle membership events only, the recipient's pointer
       circle:private:memberships:{circle_id}  ("you are now a member")

  After writing, the item is pushed live to the recipient if they are
  connected (GraphQL subscription `notificationReceived`).

  A recipient whose database does not exist (never registered) is
  reported in `failed`; the others are still delivered.
  """

  require Logger

  alias Przma.Chat.Threads
  alias Przma.Notify.{Publisher, Settings}
  alias Przma.Social.{Key, Store}

  @doc """
  Delivers `item` to every DID in `recipients`.

  Options (each may be a value or a 1-arity function of the recipient DID):
    :thread       thread key in the recipient's chat list (required)
    :thread_info  fields describing the thread (kind, peer_did, circle_id, title)
    :record       fixed record id instead of thread-msg_id (one doc per subject,
                  e.g. "follow-<follower>": a later delivery updates it)
    :pointer      circle membership pointer fields to merge for the recipient
    :count        false = do not touch the chat list / unread counter / live push
  """
  @spec deliver([String.t()], map(), keyword()) :: {:ok, %{delivered: non_neg_integer(), failed: [String.t()]}}
  def deliver(recipients, item, opts) do
    results =
      recipients
      |> Enum.uniq()
      |> Task.async_stream(fn did -> {did, deliver_one(did, item, opts)} end,
        max_concurrency: 8,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, reason} -> {nil, {:error, reason}}
      end)

    failed = for {did, {:error, reason}} <- results, do: log_failure(did, reason)
    {:ok, %{delivered: length(results) - length(failed), failed: Enum.reject(failed, &is_nil/1)}}
  end

  @doc "Hides a delivered item in someone's inbox or outbox (delete for everyone). Missing copies are fine."
  def retract(did, box, record_id) when box in ["inbox", "outbox"] do
    case Store.get(did, "chat", box, record_id) do
      {:ok, _} ->
        Store.put(did, "chat", box, record_id, %{
          "status" => "deleted",
          "content" => nil,
          "deleted_at" => System.os_time(:microsecond)
        })

      {:error, :not_found} ->
        :ok

      err ->
        err
    end
  end

  # ── private ──────────────────────────────────────────────────────────

  defp deliver_one(recipient, item, opts) do
    thread = resolve(opts[:thread], recipient)
    record = resolve(opts[:record], recipient) || Key.record(thread, item["msg_id"])
    doc = Map.merge(item, %{"thread_key" => thread, "status" => "delivered"})

    with :ok <- Store.put(recipient, "chat", "inbox", record, doc),
         :ok <- write_pointer(recipient, resolve(opts[:pointer], recipient)) do
      if Keyword.get(opts, :count, true) do
        silent = silent?(recipient, thread, item["category"])
        info = resolve(opts[:thread_info], recipient) || %{}
        Threads.touch(recipient, thread, info, item, unread: true)

        doc
        |> Map.merge(%{"id" => item["msg_id"], "direction" => "in", "read" => false, "silent" => silent})
        |> then(&Publisher.notify(recipient, &1))
      end

      :ok
    end
  end

  defp write_pointer(_recipient, nil), do: :ok

  defp write_pointer(recipient, %{"circle_id" => circle_id} = pointer),
    do: Store.put(recipient, "circle", "memberships", circle_id, pointer)

  # No alert when the recipient muted this chat or switched the category off.
  # The item is still stored and still counted, as in WhatsApp.
  defp silent?(recipient, thread, category) do
    muted =
      case Threads.get(recipient, thread) do
        {:ok, t} -> Threads.muted?(t)
        _ -> false
      end

    muted or not Settings.enabled?(recipient, category)
  end

  defp resolve(fun, did) when is_function(fun, 1), do: fun.(did)
  defp resolve(value, _did), do: value

  defp log_failure(did, reason) do
    Logger.warning("Delivery to #{inspect(did)} failed: #{inspect(reason)}")
    did
  end
end
