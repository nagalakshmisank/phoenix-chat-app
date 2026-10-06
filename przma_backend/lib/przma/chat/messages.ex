defmodule Przma.Chat.Messages do
  @moduledoc """
  Direct messages and the generic inbox/outbox reads.

      sender's database      chat:private:outbox:{thread}-{msg_id}   (what I sent)
      recipient's database   chat:private:inbox:{thread}-{msg_id}    (what I received)

  The sender writes their own outbox; Przma.Chat.Delivery writes the
  recipient's inbox. A conversation is the two boxes of one thread merged
  and sorted by message id (= by time).

  A file is sent as a message that carries `object_cas` (the hash
  returned by uploadFile/uploadBlob) and `object_name`.
  """

  alias Przma.Chat.{Delivery, Threads}
  alias Przma.Social.{Directory, Key, Store}
  alias Przma.Vault.Files

  @max_length 2000
  @default_limit 50

  # ── send ─────────────────────────────────────────────────────────────

  @doc "Sends a direct message from `me` (%{did: ...}) to `to_did`."
  def send_dm(%{did: sender}, to_did, attrs) do
    with :ok <- check(to_did != sender, :cannot_message_yourself),
         {:ok, _account} <- Directory.account(to_did),
         {:ok, item} <- build_item(sender, "Message", attrs) do
      my_thread = Key.dm_thread(to_did)

      with :ok <- write_outbox(sender, my_thread, item, [to_did]),
           :ok <- Threads.touch(sender, my_thread, %{"kind" => "dm", "peer_did" => to_did}, item),
           {:ok, report} <-
             Delivery.deliver([to_did], item,
               thread: Key.dm_thread(sender),
               thread_info: %{"kind" => "dm", "peer_did" => sender}
             ) do
        {:ok, view(Map.merge(item, %{"thread_key" => my_thread, "status" => status(report)}), "out", nil)}
      end
    end
  end

  @doc "Builds a message item. Shared with Przma.Circle.Messages."
  def build_item(sender, activity_type, attrs, extra \\ %{}) do
    content = attrs[:content]
    object_cas = attrs[:object_cas]

    cond do
      blank?(content) and blank?(object_cas) ->
        {:error, :empty_message}

      is_binary(content) and String.length(content) > @max_length ->
        {:error, :message_too_long}

      true ->
        {:ok,
         Map.merge(
           %{
             "msg_id" => Key.message_id(),
             "activity_type" => activity_type,
             "category" => if(blank?(object_cas), do: "message", else: "file"),
             "actor_did" => sender,
             "content" => content,
             "object_cas" => object_cas,
             "object_name" => attrs[:object_name],
             "object_mime" => attrs[:object_mime],
             "client_id" => attrs[:client_id],
             "sent_at" => System.os_time(:microsecond)
           },
           extra
         )}
    end
  end

  @doc "Writes the sender's own outbox copy."
  def write_outbox(sender, thread_key, item, to_dids) do
    Store.put(
      sender,
      "chat",
      "outbox",
      Key.record(thread_key, item["msg_id"]),
      Map.merge(item, %{"thread_key" => thread_key, "to_dids" => to_dids, "status" => "sent"})
    )
  end

  # ── read ─────────────────────────────────────────────────────────────

  @doc "One conversation, newest first: inbox + outbox of the thread merged. Options: :before, :limit."
  def list_thread(did, thread_key, opts \\ []) do
    limit = limit(opts)

    with {:ok, received} <- box(did, "inbox", thread_key, opts),
         {:ok, sent} <- box(did, "outbox", thread_key, opts) do
      last_read = last_read_id(did, thread_key)

      items =
        (Enum.map(received, &view(&1, "in", last_read)) ++ Enum.map(sent, &view(&1, "out", last_read)))
        |> Enum.sort_by(& &1["id"], :desc)
        |> Enum.take(limit)

      {:ok, items}
    end
  end

  @doc "Received items of one thread, newest first."
  def inbox(did, thread_key, opts \\ []) do
    with {:ok, rows} <- box(did, "inbox", thread_key, opts) do
      last_read = last_read_id(did, thread_key)
      {:ok, Enum.map(rows, &view(&1, "in", last_read))}
    end
  end

  @doc "Sent items of one thread, newest first."
  def outbox(did, thread_key, opts \\ []) do
    with {:ok, rows} <- box(did, "outbox", thread_key, opts) do
      {:ok, Enum.map(rows, &view(&1, "out", nil))}
    end
  end

  @doc "One message from either box: {:ok, box, doc}."
  def find(did, thread_key, msg_id) do
    record = Key.record(thread_key, msg_id)

    with true <- Key.valid_id?(msg_id),
         {:error, _} <- live(Store.get(did, "chat", "inbox", record)),
         {:error, _} <- live(Store.get(did, "chat", "outbox", record)) do
      {:error, :not_found}
    else
      false -> {:error, :not_found}
      {:ok, %{"status" => "sent"} = doc} -> {:ok, "outbox", doc}
      {:ok, doc} -> {:ok, "inbox", doc}
    end
  end

  def get(did, thread_key, msg_id) do
    with {:ok, box, doc} <- find(did, thread_key, msg_id) do
      {:ok, view(doc, if(box == "inbox", do: "in", else: "out"), last_read_id(did, thread_key))}
    end
  end

  # ── delete ───────────────────────────────────────────────────────────

  @doc """
  Deletes a message from the caller's own copy. With `for_everyone`
  (sender only, direct messages) the recipient's copy is hidden too.
  Circle messages are deleted through Przma.Circle.Messages.delete/3.
  """
  def delete(%{did: did}, thread_key, msg_id, for_everyone \\ false) do
    record = Key.record(thread_key, msg_id)

    with {:ok, box, doc} <- find(did, thread_key, msg_id),
         :ok <- check(not for_everyone or box == "outbox", :only_sender_can_delete_for_everyone),
         :ok <- check(not for_everyone or doc["circle_id"] == nil, :use_delete_circle_message),
         :ok <- Delivery.retract(did, box, record) do
      if for_everyone do
        Enum.each(doc["to_dids"] || [], fn peer ->
          Delivery.retract(peer, "inbox", Key.record(Key.dm_thread(did), msg_id))
        end)
      end

      {:ok, %{"id" => msg_id, "thread_key" => thread_key, "status" => "deleted"}}
    end
  end

  # ── files ────────────────────────────────────────────────────────────

  @doc "Short-lived download URL for the file attached to a message the caller sent or received."
  def blob_url(%{did: did}, thread_key, msg_id, expires_in \\ 300) do
    with {:ok, _box, %{"object_cas" => cas, "actor_did" => owner}} when is_binary(cas) <- find(did, thread_key, msg_id),
         {:ok, url} <- Files.download_url(as(owner), "read", owner, cas, expires_in: expires_in) do
      {:ok, %{url: url, expires_in: expires_in}}
    else
      {:ok, _box, _doc} -> {:error, :no_file_attached}
      err -> err
    end
  end

  @doc "Copies the file attached to a RECEIVED message into the caller's own files (private space)."
  def save_to_vault(%{did: did, gid: gid}, thread_key, msg_id) do
    with {:ok, "inbox", %{"object_cas" => cas, "actor_did" => owner} = doc} when is_binary(cas) <-
           find(did, thread_key, msg_id),
         {:ok, bytes} <- Files.download(as(owner), "read", owner, cas),
         metadata = %{
           filename: doc["object_name"] || cas,
           content_type: doc["object_mime"],
           size_bytes: byte_size(bytes)
         },
         {:ok, result} <- Files.upload(as(did), gid, bytes, metadata, space: "private"),
         :ok <-
           Store.put(did, "chat", "inbox", Key.record(thread_key, msg_id), %{
             "saved_file_id" => result.file_id
           }) do
      {:ok, result}
    else
      {:ok, _box, _doc} -> {:error, :no_received_file}
      err -> err
    end
  end

  # ── shared helpers ───────────────────────────────────────────────────

  @doc "Shapes a stored inbox/outbox document for the API."
  def view(doc, direction, last_read) do
    msg_id = doc["msg_id"]

    doc
    |> Map.put("id", msg_id)
    |> Map.put("direction", direction)
    |> Map.put("read", direction == "out" or (is_binary(last_read) and msg_id <= last_read))
  end

  defp box(did, box, thread_key, opts) do
    prefix = Key.thread_prefix(thread_key)
    before = if b = opts[:before], do: prefix <> b
    after_id = if a = opts[:after], do: prefix <> a

    # Deleted items are filtered after the read, so ask for a few more.
    with {:ok, rows} <-
           Store.list(did, "chat", box,
             prefix: prefix,
             before: before,
             after: after_id,
             limit: limit(opts) + 20,
             descending: true
           ) do
      {:ok, rows |> Enum.reject(&(&1["status"] == "deleted")) |> Enum.take(limit(opts))}
    end
  end

  defp last_read_id(did, thread_key) do
    case Threads.get(did, thread_key) do
      {:ok, %{"last_read_id" => id}} -> id
      _ -> nil
    end
  end

  defp live({:ok, %{"status" => "deleted"}}), do: {:error, :not_found}
  defp live(other), do: other

  defp limit(opts), do: opts |> Keyword.get(:limit) |> Kernel.||(@default_limit) |> min(200) |> max(1)

  defp status(%{failed: []}), do: "sent"
  defp status(_), do: "undelivered"

  defp as(did), do: %{did: did, origin_instance_id: nil, portable_grant: nil}

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}
end
