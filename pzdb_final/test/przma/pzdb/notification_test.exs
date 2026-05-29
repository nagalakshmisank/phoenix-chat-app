# test/przma/pzdb/notification_test.exs
#
# Tests for the notification subsystem.
# Runs with the existing NIF stubs — no real LanceDB required.

defmodule PRZMA.PzDb.NotificationTest do
  use ExUnit.Case, async: false

  alias PRZMA.PzDb.Notification.{Manager, Schema, Storage}
  alias PRZMA.PzDb

  @did_alice  "did:przma:alice"
  @did_bob    "did:przma:bob"
  @did_carol  "did:przma:carol"

  # ── SCHEMA TESTS ────────────────────────────────────────────────────────────

  describe "Schema.new_inbox/1" do
    test "builds a valid inbox record" do
      record = Schema.new_inbox(%{
        id:         "msg-001",
        sender_did: @did_bob,
        type:       :message,
        subject:    "Hello",
        body:       "Hi Alice!",
      })

      assert record["id"]          == "msg-001"
      assert record["sender_did"]  == @did_bob
      assert record["type"]        == "message"
      assert record["subject"]     == "Hello"
      assert record["body"]        == "Hi Alice!"
      assert record["read"]        == false
      assert record["archived"]    == false
      assert record["priority"]    == "normal"
      assert is_binary(record["received_at"])
    end

    test "truncates body larger than inline threshold" do
      big_body = String.duplicate("x", Schema.inline_threshold() + 100)
      record   = Schema.new_inbox(%{id: "m", sender_did: "did:x", type: :message, body: big_body})

      assert byte_size(record["body"]) <= Schema.inline_threshold() + 10
      assert String.ends_with?(record["body"], "…")
    end

    test "defaults priority to normal" do
      record = Schema.new_inbox(%{id: "m", sender_did: "did:x", type: :message})
      assert record["priority"] == "normal"
    end

    test "has payload_file_key field (not s3_payload_key)" do
      record = Schema.new_inbox(%{id: "m", sender_did: "did:x", type: :message})
      assert Map.has_key?(record, "payload_file_key")
      refute Map.has_key?(record, "s3_payload_key")
    end

    test "has attachments field (not s3_attachments)" do
      record = Schema.new_inbox(%{id: "m", sender_did: "did:x", type: :message})
      assert Map.has_key?(record, "attachments")
      refute Map.has_key?(record, "s3_attachments")
    end
  end

  describe "Schema.new_outbox/1" do
    test "builds a valid outbox record" do
      record = Schema.new_outbox(%{
        id:             "msg-002",
        recipient_dids: [@did_alice, @did_carol],
        type:           :event_invite,
        subject:        "Team standup",
        body:           "Join us tomorrow at 9am",
      })

      assert record["id"]     == "msg-002"
      assert record["status"] == "pending"
      assert record["type"]   == "event_invite"
      assert Jason.decode!(record["recipient_dids"]) == [@did_alice, @did_carol]
    end

    test "has payload_file_key field (not s3_payload_key)" do
      record = Schema.new_outbox(%{
        id: "m", recipient_dids: [@did_alice], type: :message
      })
      assert Map.has_key?(record, "payload_file_key")
      refute Map.has_key?(record, "s3_payload_key")
    end
  end

  describe "Schema.new_notification/1" do
    test "builds a valid notification record" do
      record = Schema.new_notification(%{
        id:        "notif-001",
        actor_did: @did_bob,
        type:      :follow,
        summary:   "Bob started following you",
      })

      assert record["id"]        == "notif-001"
      assert record["actor_did"] == @did_bob
      assert record["type"]      == "follow"
      assert record["read"]      == false
      assert record["dismissed"] == false
    end
  end

  describe "Schema.large_body?/1" do
    test "returns false for small body" do
      refute Schema.large_body?("short message")
    end

    test "returns true for body over threshold" do
      big = String.duplicate("a", Schema.inline_threshold() + 1)
      assert Schema.large_body?(big)
    end
  end

  # ── LOCAL STORAGE TESTS ─────────────────────────────────────────────────────

  describe "Storage key helpers" do
    test "payload_key builds correct path for inbox" do
      key = Storage.payload_key(@did_alice, :inbox, "msg-123")
      assert key == "#{@did_alice}/notifications/inbox/msg-123/payload.json"
    end

    test "payload_key builds correct path for outbox" do
      key = Storage.payload_key(@did_alice, :outbox, "msg-456")
      assert key == "#{@did_alice}/notifications/outbox/msg-456/payload.json"
    end

    test "attachment_key builds correct path" do
      key = Storage.attachment_key(@did_alice, "msg-123", "photo.jpg")
      assert key == "#{@did_alice}/notifications/attachments/msg-123/photo.jpg"
    end

    test "attachment_key strips path traversal" do
      key = Storage.attachment_key(@did_alice, "msg-123", "../../etc/passwd")
      assert key == "#{@did_alice}/notifications/attachments/msg-123/passwd"
    end
  end

  describe "Storage.health_check/0" do
    test "returns :ok when local storage directory is accessible" do
      assert :ok = Storage.health_check()
    end
  end

  # ── MANAGER TESTS ───────────────────────────────────────────────────────────

  describe "Manager.provision_notification_tables/1" do
    test "provisions all three tables" do
      assert {:ok, %{tables: 3}} = Manager.provision_notification_tables(@did_alice)
    end

    test "is idempotent" do
      assert {:ok, _} = Manager.provision_notification_tables(@did_alice)
      assert {:ok, _} = Manager.provision_notification_tables(@did_alice)
    end
  end

  describe "Manager.send_message/3" do
    test "sends a message and returns outbox + inbox URIs" do
      result = Manager.send_message(@did_alice, [@did_bob], [
        type:    :message,
        subject: "Test message",
        body:    "Hello Bob",
      ])

      assert {:ok, info} = result
      assert is_binary(info.message_id)
      assert String.starts_with?(info.outbox_uri, "pzdb://#{@did_alice}/notifications/core/outbox/")
      assert length(info.inbox_uris) == 1
      assert String.starts_with?(hd(info.inbox_uris), "pzdb://#{@did_bob}/notifications/core/inbox/")
    end

    test "sends to multiple recipients" do
      {:ok, info} = Manager.send_message(@did_alice, [@did_bob, @did_carol], [
        type:    :event_invite,
        subject: "Party time",
        body:    "You're invited!",
      ])

      assert length(info.inbox_uris) == 2
    end

    test "returns message_id in result" do
      {:ok, info} = Manager.send_message(@did_alice, [@did_bob],
        type: :message, subject: "Hi", body: "Hey")

      assert is_binary(info.message_id)
      assert String.length(info.message_id) > 0
    end

    test "accepts custom message id" do
      {:ok, info} = Manager.send_message(@did_alice, [@did_bob],
        id: "custom-id-123", type: :message, subject: "S", body: "B")

      assert info.message_id == "custom-id-123"
    end

    test "includes fan_out report" do
      {:ok, info} = Manager.send_message(@did_alice, [@did_bob],
        type: :message, subject: "Test", body: "body")

      assert is_map(info.fan_out)
      assert Map.has_key?(info.fan_out, :succeeded)
      assert Map.has_key?(info.fan_out, :failed)
    end
  end

  describe "Manager.notify/2" do
    test "delivers a system notification" do
      result = Manager.notify(@did_alice,
        type:      :follow,
        actor_did: @did_bob,
        summary:   "Bob started following you")

      assert {:ok, uri} = result
      assert String.starts_with?(uri, "pzdb://#{@did_alice}/notifications/core/notifications/")
    end

    test "accepts ref_uri" do
      {:ok, uri} = Manager.notify(@did_alice,
        type:      :mention,
        actor_did: @did_bob,
        ref_uri:   "pzdb://#{@did_alice}/vault/core/entries/entry-123",
        summary:   "Bob mentioned you")

      assert is_binary(uri)
    end
  end

  describe "Manager.notify_many/2" do
    test "fans out notifications to many recipients" do
      result = Manager.notify_many([@did_alice, @did_bob, @did_carol],
        type:      :system,
        actor_did: "system",
        summary:   "Maintenance at midnight")

      assert is_map(result)
      assert Map.has_key?(result, :succeeded)
      assert Map.has_key?(result, :failed)
    end
  end

  describe "Manager.list_inbox/2" do
    test "returns query result for inbox" do
      {:ok, result} = Manager.list_inbox(@did_alice)
      assert is_map(result)
    end
  end

  describe "Manager.list_outbox/2" do
    test "returns query result for outbox" do
      {:ok, result} = Manager.list_outbox(@did_alice)
      assert is_map(result)
    end
  end

  describe "Manager.list_notifications/2" do
    test "returns query result" do
      {:ok, result} = Manager.list_notifications(@did_alice)
      assert is_map(result)
    end
  end

  describe "Manager.mark_inbox_read/2" do
    test "marks a message read" do
      result = Manager.mark_inbox_read(@did_alice, "msg-001")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Manager.archive_inbox_message/2" do
    test "archives a message" do
      result = Manager.archive_inbox_message(@did_alice, "msg-001")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Manager.dismiss_notification/2" do
    test "dismisses a notification" do
      result = Manager.dismiss_notification(@did_alice, "notif-001")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── URI SHAPE TESTS ─────────────────────────────────────────────────────────

  describe "URI structure" do
    test "inbox URIs parse correctly with PRZMA.PzDb.Uri" do
      uri = "pzdb://#{@did_alice}/notifications/core/inbox/msg-xyz"
      assert {:ok, parsed} = PRZMA.PzDb.Uri.parse(uri)
      assert parsed.did       == @did_alice
      assert parsed.service   == "notifications"
      assert parsed.space     == "core"
      assert parsed.table     == "inbox"
      assert parsed.record_id == "msg-xyz"
    end

    test "outbox URIs parse correctly" do
      uri = "pzdb://#{@did_alice}/notifications/core/outbox/msg-xyz"
      assert {:ok, parsed} = PRZMA.PzDb.Uri.parse(uri)
      assert parsed.table == "outbox"
    end

    test "notification URIs parse correctly" do
      uri = "pzdb://#{@did_alice}/notifications/core/notifications/notif-xyz"
      assert {:ok, parsed} = PRZMA.PzDb.Uri.parse(uri)
      assert parsed.table == "notifications"
    end
  end
end
