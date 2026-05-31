# lib/przma/pzdb/notification/schema.ex
#
# Defines the canonical record shapes for inbox, outbox, and notification tables.
#
# pzdb URI layout for notifications (all under "notifications/core/"):
#
#   pzdb://<did>/notifications/core/inbox/<message_id>
#   pzdb://<did>/notifications/core/outbox/<message_id>
#   pzdb://<did>/notifications/core/notifications/<notif_id>
#
# Local file storage:
#   Large payloads > @inline_threshold_bytes are stored as local files instead
#   of inline in LanceDB. The pzdb record stores the local file key and the
#   retrieval layer fetches and inlines on read.
#
#   Local storage layout (under vault base_path):
#     notifications_storage/{did}/notifications/inbox/{message_id}/payload.json
#     notifications_storage/{did}/notifications/outbox/{message_id}/payload.json
#     notifications_storage/{did}/notifications/attachments/{message_id}/{filename}

defmodule PRZMA.PzDb.Notification.Schema do
  @moduledoc """
  Canonical record shapes and helper constructors for the notification subsystem.
  """

  # Payloads larger than this are stored as local files instead of inline in LanceDB
  @inline_threshold_bytes 8_192

  # ── INBOX RECORD ────────────────────────────────────────────────────────────
  # Stored at: pzdb://<recipient_did>/notifications/core/inbox/<message_id>

  @doc """
  Build a new inbox record.

  Required keys:
    :id           — unique message ID (UUID v4 recommended)
    :sender_did   — DID of the sending party
    :type         — atom/string: :message | :event_invite | :follow_request |
                    :circle_invite | :system | :alert | custom
    :subject      — short plaintext subject line
    :body         — plaintext or rich text body

  Optional:
    :thread_id        — groups messages into a conversation thread
    :ref_uri          — pzdb:// URI of the object this notification is about
    :metadata         — arbitrary JSON map for service-specific context
    :priority         — :normal (default) | :high | :urgent
    :expires_at       — ISO 8601 UTC; nil = never expires
    :payload_file_key — when body is large, local file key of full payload
    :attachments      — list of %{filename: _, local_key: _}
  """
  def new_inbox(fields) when is_map(fields) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "id"               => Map.fetch!(fields, :id),
      "sender_did"       => Map.fetch!(fields, :sender_did),
      "type"             => to_string(Map.fetch!(fields, :type)),
      "subject"          => Map.get(fields, :subject, ""),
      "body"             => maybe_truncate_body(Map.get(fields, :body, "")),
      "thread_id"        => Map.get(fields, :thread_id),
      "ref_uri"          => Map.get(fields, :ref_uri),
      "metadata"         => Jason.encode!(Map.get(fields, :metadata, %{})),
      "priority"         => to_string(Map.get(fields, :priority, :normal)),
      "read"             => false,
      "read_at"          => nil,
      "archived"         => false,
      "archived_at"      => nil,
      "deleted_at"       => nil,
      "expires_at"       => Map.get(fields, :expires_at),
      "payload_file_key" => Map.get(fields, :payload_file_key),
      "attachments"      => Jason.encode!(Map.get(fields, :attachments, [])),
      "received_at"      => now,
      "created_at"       => now,
      "updated_at"       => now,
    }
  end

  # ── OUTBOX RECORD ───────────────────────────────────────────────────────────
  # Stored at: pzdb://<sender_did>/notifications/core/outbox/<message_id>

  @doc """
  Build a new outbox record.

  Required keys:
    :id             — unique message ID (must match inbox record IDs)
    :recipient_dids — list of recipient DIDs
    :type           — same type atoms as inbox
    :subject        — plaintext subject
    :body           — plaintext or rich text body

  Optional:
    :thread_id        — conversation thread ID
    :ref_uri          — the pzdb:// URI this message references
    :metadata         — arbitrary JSON map
    :priority         — :normal | :high | :urgent
    :scheduled_at     — ISO 8601 UTC; deliver at this time (nil = immediate)
    :payload_file_key — local file key when body is large
    :attachments      — list of %{filename: _, local_key: _}
  """
  def new_outbox(fields) when is_map(fields) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "id"               => Map.fetch!(fields, :id),
      "recipient_dids"   => Jason.encode!(Map.fetch!(fields, :recipient_dids)),
      "type"             => to_string(Map.fetch!(fields, :type)),
      "subject"          => Map.get(fields, :subject, ""),
      "body"             => maybe_truncate_body(Map.get(fields, :body, "")),
      "thread_id"        => Map.get(fields, :thread_id),
      "ref_uri"          => Map.get(fields, :ref_uri),
      "metadata"         => Jason.encode!(Map.get(fields, :metadata, %{})),
      "priority"         => to_string(Map.get(fields, :priority, :normal)),
      "status"           => "pending",
      "delivery_report"  => Jason.encode!(%{}),
      "scheduled_at"     => Map.get(fields, :scheduled_at),
      "sent_at"          => nil,
      "payload_file_key" => Map.get(fields, :payload_file_key),
      "attachments"      => Jason.encode!(Map.get(fields, :attachments, [])),
      "created_at"       => now,
      "updated_at"       => now,
    }
  end

  # ── NOTIFICATION RECORD ─────────────────────────────────────────────────────
  # Stored at: pzdb://<did>/notifications/core/notifications/<notif_id>
  # Lightweight, ephemeral system-level event (e.g. "new follower", "mention").
  # Different from inbox: no body blob, no thread, no reply workflow.

  @doc """
  Build a notification record.

  Required keys:
    :id         — unique notification ID
    :actor_did  — the DID that caused this notification (e.g. who followed you)
    :type       — :follow | :mention | :like | :comment | :system | custom

  Optional:
    :ref_uri    — pzdb:// URI of the object (the post that was liked, etc.)
    :summary    — one-line human-readable summary
    :metadata   — JSON map for rendering hints
  """
  def new_notification(fields) when is_map(fields) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    %{
      "id"           => Map.fetch!(fields, :id),
      "actor_did"    => Map.fetch!(fields, :actor_did),
      "type"         => to_string(Map.fetch!(fields, :type)),
      "ref_uri"      => Map.get(fields, :ref_uri),
      "summary"      => Map.get(fields, :summary, ""),
      "metadata"     => Jason.encode!(Map.get(fields, :metadata, %{})),
      "read"         => false,
      "read_at"      => nil,
      "dismissed"    => false,
      "dismissed_at" => nil,
      "deleted_at"   => nil,
      "created_at"   => now,
      "updated_at"   => now,
    }
  end

  # ── HELPERS ─────────────────────────────────────────────────────────────────

  @doc "True when the body should be stored as a local file rather than inline in LanceDB."
  def large_body?(body) when is_binary(body), do: byte_size(body) > @inline_threshold_bytes
  def large_body?(_), do: false

  @doc "Inline threshold in bytes"
  def inline_threshold, do: @inline_threshold_bytes

  defp maybe_truncate_body(body) when is_binary(body) do
    if byte_size(body) > @inline_threshold_bytes do
      binary_part(body, 0, @inline_threshold_bytes) <> "…"
    else
      body
    end
  end
  defp maybe_truncate_body(body), do: to_string(body)
end
