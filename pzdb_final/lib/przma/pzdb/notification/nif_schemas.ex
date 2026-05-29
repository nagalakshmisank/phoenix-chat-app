# lib/przma/pzdb/notification/nif_schemas.ex
#
# Describes the LanceDB table schemas expected for notification tables.
# This is documentation for the Rust NIF's pzdb_provision_table/3 call.
#
# In production the schema name string maps to a Rust-side Arrow schema
# definition in the NIF. The stubs in stubs.ex ignore this; in the real
# system, add these three schema names to the Rust NIF's schema registry.

defmodule PRZMA.PzDb.Notification.NifSchemas do
  @moduledoc """
  LanceDB Arrow schemas for notification tables.
  These names are passed as the `schema_name` argument to pzdb_provision_table.

  In the Rust NIF, register these under the names:
    "inbox"         → InboxSchema
    "outbox"        → OutboxSchema
    "notifications" → NotificationSchema

  Arrow field definitions (Rust pseudo-code):
  ─────────────────────────────────────────────────────

  InboxSchema:
    id               Utf8        not null
    sender_did       Utf8        not null
    type             Utf8        not null
    subject          Utf8
    body             Utf8              -- truncated to 8 KB inline
    thread_id        Utf8              -- nullable
    ref_uri          Utf8              -- nullable
    metadata         Utf8              -- JSON string
    priority         Utf8              -- "normal" | "high" | "urgent"
    read             Boolean     not null  default false
    read_at          Utf8              -- nullable ISO 8601
    archived         Boolean     not null  default false
    archived_at      Utf8              -- nullable ISO 8601
    deleted_at       Utf8              -- nullable ISO 8601 (soft delete)
    expires_at       Utf8              -- nullable ISO 8601
    s3_payload_key   Utf8              -- nullable; set when body > 8 KB
    s3_attachments   Utf8              -- JSON array of {filename, s3_key}
    received_at      Utf8        not null
    created_at       Utf8        not null
    updated_at       Utf8        not null

  OutboxSchema:
    id               Utf8        not null
    recipient_dids   Utf8        not null  -- JSON array
    type             Utf8        not null
    subject          Utf8
    body             Utf8
    thread_id        Utf8
    ref_uri          Utf8
    metadata         Utf8              -- JSON string
    priority         Utf8
    status           Utf8        not null  -- "pending"|"sending"|"delivered"|"partial"|"failed"|"cancelled"
    delivery_report  Utf8              -- JSON map {succeeded, failed, errors}
    scheduled_at     Utf8              -- nullable ISO 8601
    sent_at          Utf8              -- nullable ISO 8601
    s3_payload_key   Utf8
    s3_attachments   Utf8              -- JSON array
    created_at       Utf8        not null
    updated_at       Utf8        not null

  NotificationSchema:
    id               Utf8        not null
    actor_did        Utf8        not null
    type             Utf8        not null
    ref_uri          Utf8
    summary          Utf8
    metadata         Utf8              -- JSON string
    read             Boolean     not null  default false
    read_at          Utf8
    dismissed        Boolean     not null  default false
    dismissed_at     Utf8
    deleted_at       Utf8
    created_at       Utf8        not null
    updated_at       Utf8        not null

  ─────────────────────────────────────────────────────
  All timestamp fields store ISO 8601 UTC strings for portability.
  The Lance OCC key column for all three tables is ["id"].
  """

  def schema_names, do: ["inbox", "outbox", "notifications"]
end
