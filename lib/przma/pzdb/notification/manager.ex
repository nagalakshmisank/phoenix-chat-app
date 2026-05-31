# lib/przma/pzdb/notification/manager.ex
#
# High-level API for the notification subsystem.
#
# Responsibilities:
#   - Provision notification tables for a DID (inbox, outbox, notifications)
#   - Send a message: write outbox record for sender → fan-out inbox records to all recipients
#   - Query inbox / outbox with filters (unread, type, thread, priority)
#   - Mark inbox records as read / archived
#   - Dismiss / delete notifications
#   - Deliver system notifications to a DID
#   - Offload large bodies to local file storage transparently
#
# pzdb URI structure:
#   pzdb://<did>/notifications/core/inbox/<message_id>
#   pzdb://<did>/notifications/core/outbox/<message_id>
#   pzdb://<did>/notifications/core/notifications/<notif_id>

defmodule PRZMA.PzDb.Notification.Manager do
  alias PRZMA.PzDb
  alias PRZMA.PzDb.Notification.{Schema, Storage}
  require Logger

  # ── TABLE PROVISIONING ──────────────────────────────────────────────────────

  @doc """
  Create the three notification tables for a DID.
  Idempotent — safe to call on every boot or account creation.

  Returns {:ok, %{tables: 3}} | {:error, reason}
  """
  def provision_notification_tables(did) do
    tables = [
      {"notifications/core/inbox",         "inbox"},
      {"notifications/core/outbox",        "outbox"},
      {"notifications/core/notifications", "notifications"},
    ]

    results = Enum.map(tables, fn {path, schema} ->
      uri = "pzdb://#{did}/#{path}/placeholder"
      {path, PzDb.ensure_table(uri, schema)}
    end)

    failed = Enum.filter(results, fn {_, r} -> match?({:error, _}, r) end)

    if Enum.empty?(failed) do
      Logger.info("Notification tables provisioned", did: did)
      {:ok, %{tables: length(tables)}}
    else
      Logger.error("Notification table provisioning failed", did: did, failed: inspect(failed))
      {:error, %{failed: failed}}
    end
  end

  # ── SEND (write outbox + fan-out inbox) ─────────────────────────────────────

  @doc """
  Send a message from sender_did to one or more recipient DIDs.

  opts:
    :type        — :message | :event_invite | :follow_request | :system | custom (required)
    :subject     — string
    :body        — string (large bodies are automatically stored as local files)
    :thread_id   — group into a conversation thread
    :ref_uri     — pzdb:// URI this message concerns
    :metadata    — map
    :priority    — :normal | :high | :urgent
    :attachments — list of %{filename: _, data: _, content_type: _}

  Returns {:ok, %{message_id: _, outbox_uri: _, inbox_uris: [...]}} | {:error, reason}
  """
  def send_message(sender_did, recipient_dids, opts \\ [])
      when is_binary(sender_did) and is_list(recipient_dids) do
    message_id = opts[:id] || generate_id()
    body       = opts[:body] || ""
    type       = Keyword.fetch!(opts, :type)

    # 1. Offload large body to local file storage
    {body_inline, payload_file_key} =
      if Schema.large_body?(body) do
        case Storage.put_payload(sender_did, :outbox, message_id, body) do
          {:ok, key} ->
            Logger.debug("Large outbox body stored locally", key: key)
            {body, key}
          {:error, reason} ->
            Logger.error("Local payload storage failed; storing inline", reason: reason)
            {body, nil}
        end
      else
        {body, nil}
      end

    # 2. Store attachments locally
    local_attachments =
      Enum.flat_map(opts[:attachments] || [], fn att ->
        case Storage.put_attachment(sender_did, message_id, att.filename, att.data,
               Map.get(att, :content_type, "application/octet-stream")) do
          {:ok, key} -> [%{filename: att.filename, local_key: key}]
          {:error, r} ->
            Logger.error("Attachment storage failed", file: att.filename, reason: r)
            []
        end
      end)

    # 3. Write outbox record for sender
    outbox_record = Schema.new_outbox(%{
      id:               message_id,
      recipient_dids:   recipient_dids,
      type:             type,
      subject:          opts[:subject] || "",
      body:             body_inline,
      thread_id:        opts[:thread_id],
      ref_uri:          opts[:ref_uri],
      metadata:         opts[:metadata] || %{},
      priority:         opts[:priority] || :normal,
      payload_file_key: payload_file_key,
      attachments:      local_attachments,
    })
    outbox_uri = build_uri(sender_did, :outbox, message_id)

    with {:ok, _} <- PzDb.write(outbox_uri, outbox_record) do
      # 4. Fan-out inbox records to all recipients
      inbox_pairs = Enum.map(recipient_dids, fn recipient_did ->
        # Each recipient gets their own local payload copy
        recipient_payload_key =
          if payload_file_key do
            case Storage.put_payload(recipient_did, :inbox, message_id, body) do
              {:ok, key} -> key
              _          -> payload_file_key
            end
          end

        inbox_record = Schema.new_inbox(%{
          id:               message_id,
          sender_did:       sender_did,
          type:             type,
          subject:          opts[:subject] || "",
          body:             body_inline,
          thread_id:        opts[:thread_id],
          ref_uri:          opts[:ref_uri],
          metadata:         opts[:metadata] || %{},
          priority:         opts[:priority] || :normal,
          payload_file_key: recipient_payload_key,
          attachments:      local_attachments,
        })
        {build_uri(recipient_did, :inbox, message_id), inbox_record}
      end)

      fan_result = PzDb.fan_out(inbox_pairs)

      # 5. Update outbox status based on fan-out result
      status =
        if Enum.empty?(fan_result.failed), do: "delivered", else: "partial"

      update_outbox_status(sender_did, message_id, status, %{
        fan_out: %{
          succeeded: length(fan_result.succeeded),
          failed:    length(fan_result.failed),
          errors:    Enum.map(fan_result.failed, fn {uri, r} -> %{uri: uri, reason: inspect(r)} end),
        }
      })

      Logger.info("Message sent",
        message_id: message_id,
        sender: sender_did,
        recipients: length(recipient_dids),
        fan_out_failed: length(fan_result.failed))

      {:ok, %{
        message_id: message_id,
        outbox_uri: outbox_uri,
        inbox_uris: Enum.map(inbox_pairs, &elem(&1, 0)),
        fan_out:    fan_result,
      }}
    end
  end

  # ── DELIVER SYSTEM NOTIFICATION ─────────────────────────────────────────────

  @doc """
  Deliver a system-level notification to a DID.
  Lightweight — no body blob, no thread, no fan-out.

  Returns {:ok, notif_uri} | {:error, reason}
  """
  def notify(recipient_did, opts \\ []) do
    notif_id = opts[:id] || generate_id()
    type     = Keyword.fetch!(opts, :type)

    record = Schema.new_notification(%{
      id:        notif_id,
      actor_did: opts[:actor_did] || "system",
      type:      type,
      ref_uri:   opts[:ref_uri],
      summary:   opts[:summary] || "",
      metadata:  opts[:metadata] || %{},
    })

    uri = build_uri(recipient_did, :notifications, notif_id)

    case PzDb.write(uri, record) do
      {:ok, _} ->
        Logger.debug("Notification delivered", did: recipient_did, type: type, id: notif_id)
        {:ok, uri}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fan-out a notification to many DIDs at once (e.g. new-follower blast).
  Returns %{succeeded: [...], failed: [...]}
  """
  def notify_many(recipient_dids, opts \\ []) when is_list(recipient_dids) do
    type     = Keyword.fetch!(opts, :type)
    actor    = opts[:actor_did] || "system"
    ref_uri  = opts[:ref_uri]
    summary  = opts[:summary] || ""
    metadata = opts[:metadata] || %{}

    pairs = Enum.map(recipient_dids, fn did ->
      notif_id = generate_id()
      record = Schema.new_notification(%{
        id:        notif_id,
        actor_did: actor,
        type:      type,
        ref_uri:   ref_uri,
        summary:   summary,
        metadata:  metadata,
      })
      {build_uri(did, :notifications, notif_id), record}
    end)

    PzDb.fan_out(pairs)
  end

  # ── INBOX QUERIES ───────────────────────────────────────────────────────────

  @doc """
  List inbox messages for a DID.

  opts:
    :limit        — max records (default 50)
    :unread_only  — boolean (default false)
    :type         — filter by message type string
    :thread_id    — filter by thread
    :priority     — filter by priority
    :archived     — include archived (default false)
  """
  def list_inbox(did, opts \\ []) do
    table_uri = "pzdb://#{did}/notifications/core/inbox/placeholder"
    filter    = build_inbox_filter(opts)
    limit     = opts[:limit] || 50

    PzDb.query(table_uri, filter: filter, limit: limit)
  end

  @doc "Read a single inbox message, hydrating large bodies from local storage."
  def get_inbox_message(did, message_id) do
    uri = build_uri(did, :inbox, message_id)

    with {:ok, %{record: record, found: true}} <- PzDb.read(uri) do
      record = maybe_hydrate_body(record)
      {:ok, record}
    else
      {:ok, %{found: false}} -> {:error, :not_found}
      err                    -> err
    end
  end

  # ── OUTBOX QUERIES ──────────────────────────────────────────────────────────

  @doc """
  List outbox messages for a DID.

  opts:
    :limit        — max records (default 50)
    :status       — filter by status string ("pending", "delivered", "failed")
    :type         — filter by message type
  """
  def list_outbox(did, opts \\ []) do
    table_uri = "pzdb://#{did}/notifications/core/outbox/placeholder"
    filter    = build_outbox_filter(opts)
    limit     = opts[:limit] || 50

    PzDb.query(table_uri, filter: filter, limit: limit)
  end

  @doc "Read a single outbox message, hydrating large bodies from local storage."
  def get_outbox_message(did, message_id) do
    uri = build_uri(did, :outbox, message_id)

    with {:ok, %{record: record, found: true}} <- PzDb.read(uri) do
      record = maybe_hydrate_body(record)
      {:ok, record}
    else
      {:ok, %{found: false}} -> {:error, :not_found}
      err                    -> err
    end
  end

  # ── NOTIFICATION QUERIES ────────────────────────────────────────────────────

  @doc """
  List notifications for a DID.

  opts:
    :limit        — max records (default 50)
    :unread_only  — boolean (default false)
    :type         — filter by notification type
  """
  def list_notifications(did, opts \\ []) do
    table_uri = "pzdb://#{did}/notifications/core/notifications/placeholder"
    filter    = build_notification_filter(opts)
    limit     = opts[:limit] || 50

    PzDb.query(table_uri, filter: filter, limit: limit)
  end

  @doc "Unread notification count for a DID."
  def unread_count(did) do
    with {:ok, result} <- list_notifications(did, unread_only: true, limit: 1000) do
      {:ok, length(result["records"] || [])}
    end
  end

  # ── STATE MUTATIONS ─────────────────────────────────────────────────────────

  @doc "Mark an inbox message as read."
  def mark_inbox_read(did, message_id) do
    uri = build_uri(did, :inbox, message_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    PzDb.write(uri, %{"id" => message_id, "read" => true, "read_at" => now, "updated_at" => now},
      key_columns: ["id"])
  end

  @doc "Mark multiple inbox messages as read."
  def mark_inbox_read_many(did, message_ids) when is_list(message_ids) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    pairs = Enum.map(message_ids, fn id ->
      uri    = build_uri(did, :inbox, id)
      record = %{"id" => id, "read" => true, "read_at" => now, "updated_at" => now}
      {uri, record}
    end)
    PzDb.fan_out(pairs, key_columns: ["id"])
  end

  @doc "Archive an inbox message."
  def archive_inbox_message(did, message_id) do
    uri = build_uri(did, :inbox, message_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    PzDb.write(uri,
      %{"id" => message_id, "archived" => true, "archived_at" => now, "updated_at" => now},
      key_columns: ["id"])
  end

  @doc "Soft-delete an inbox message."
  def delete_inbox_message(did, message_id) do
    uri = build_uri(did, :inbox, message_id)
    PzDb.delete(uri, did)
  end

  @doc "Mark a notification as read."
  def mark_notification_read(did, notif_id) do
    uri = build_uri(did, :notifications, notif_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    PzDb.write(uri,
      %{"id" => notif_id, "read" => true, "read_at" => now, "updated_at" => now},
      key_columns: ["id"])
  end

  @doc "Mark all notifications as read for a DID."
  def mark_all_notifications_read(did) do
    with {:ok, result} <- list_notifications(did, unread_only: true, limit: 1000) do
      ids = Enum.map(result["records"] || [], & &1["id"])
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      pairs = Enum.map(ids, fn id ->
        uri = build_uri(did, :notifications, id)
        {uri, %{"id" => id, "read" => true, "read_at" => now, "updated_at" => now}}
      end)
      PzDb.fan_out(pairs, key_columns: ["id"])
    end
  end

  @doc "Dismiss a notification (hide from feed but keep for audit)."
  def dismiss_notification(did, notif_id) do
    uri = build_uri(did, :notifications, notif_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    PzDb.write(uri,
      %{"id" => notif_id, "dismissed" => true, "dismissed_at" => now, "updated_at" => now},
      key_columns: ["id"])
  end

  # ── PRIVATE HELPERS ─────────────────────────────────────────────────────────

  defp build_uri(did, :inbox, id),         do: "pzdb://#{did}/notifications/core/inbox/#{id}"
  defp build_uri(did, :outbox, id),        do: "pzdb://#{did}/notifications/core/outbox/#{id}"
  defp build_uri(did, :notifications, id), do: "pzdb://#{did}/notifications/core/notifications/#{id}"

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> (fn b ->
         <<a::binary-size(8), b::binary-size(4), c::binary-size(4),
           d::binary-size(4), e::binary-size(12)>> = b
         "#{a}-#{b}-#{c}-#{d}-#{e}"
       end).()
  end

  defp build_inbox_filter(opts) do
    clauses =
      []
      |> maybe_add("deleted_at IS NULL")
      |> maybe_add_eq("read",      opts[:unread_only] && "false")
      |> maybe_add_eq("type",      opts[:type] && "'#{opts[:type]}'")
      |> maybe_add_eq("thread_id", opts[:thread_id] && "'#{opts[:thread_id]}'")
      |> maybe_add_eq("priority",  opts[:priority] && "'#{opts[:priority]}'")
      |> then(fn c ->
           if opts[:archived] == true, do: c,
             else: ["archived = false" | c]
         end)
    Enum.join(clauses, " AND ")
  end

  defp build_outbox_filter(opts) do
    []
    |> maybe_add("deleted_at IS NULL")
    |> maybe_add_eq("status", opts[:status] && "'#{opts[:status]}'")
    |> maybe_add_eq("type",   opts[:type] && "'#{opts[:type]}'")
    |> Enum.join(" AND ")
  end

  defp build_notification_filter(opts) do
    []
    |> maybe_add("deleted_at IS NULL")
    |> maybe_add("dismissed = false")
    |> maybe_add_eq("read", opts[:unread_only] && "false")
    |> maybe_add_eq("type", opts[:type] && "'#{opts[:type]}'")
    |> Enum.join(" AND ")
  end

  defp maybe_add(clauses, clause), do: [clause | clauses]
  defp maybe_add_eq(clauses, _col, nil), do: clauses
  defp maybe_add_eq(clauses, col, val),  do: ["#{col} = #{val}" | clauses]

  # If record has a payload_file_key, fetch the full body from local storage
  defp maybe_hydrate_body(%{"payload_file_key" => key} = record)
       when is_binary(key) and key != "" do
    case Storage.get_payload(key) do
      {:ok, body} ->
        Map.put(record, "body", body)
      {:error, reason} ->
        Logger.warning("Local payload hydration failed", key: key, reason: reason)
        record
    end
  end
  defp maybe_hydrate_body(record), do: record

  defp update_outbox_status(did, message_id, status, delivery_report) do
    uri = build_uri(did, :outbox, message_id)
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    PzDb.write(uri, %{
      "id"              => message_id,
      "status"          => status,
      "sent_at"         => now,
      "delivery_report" => Jason.encode!(delivery_report),
      "updated_at"      => now,
    }, key_columns: ["id"])
  end
end
