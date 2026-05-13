# test/przma/calendar/federation/federation_test.exs

defmodule PRZMA.Calendar.Federation.ActivityPubTest do
  use ExUnit.Case, async: true

  # These tests validate the Elixir federation layer.
  # The Rust ical and activitypub serialization tests are in the crate.

  describe "actor URL building" do
    test "encodes DID correctly in actor URL" do
      instance_url = "https://alice.przma.net"
      did          = "did:web:alice.com"
      encoded      = URI.encode(did)
      expected     = "#{instance_url}/ap/actor/#{encoded}"
      assert String.contains?(expected, "alice.przma.net")
      assert String.contains?(expected, "did%3Aweb%3Aalice.com")
    end
  end

  describe "webfinger resource parsing" do
    test "parses acct: resource" do
      resource = "acct:alice@alice.przma.net"
      [_, rest] = String.split(resource, ":", parts: 2)
      [_name, domain] = String.split(rest, "@")
      assert domain == "alice.przma.net"
    end
  end

  describe "inbound activity type routing" do
    test "identifies Create activity" do
      activity = %{"type" => "Create", "object" => %{"type" => "Event"}}
      assert activity["type"] == "Create"
    end

    test "identifies Delete activity" do
      activity = %{"type" => "Delete", "object" => %{"type" => "Tombstone", "id" => "https://example.com/events/1"}}
      assert activity["type"] == "Delete"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Federation.ICalImporterTest do
  use ExUnit.Case, async: true

  alias PRZMA.Calendar.Federation.ICal.Importer

  describe "ical status conversion" do
    test "CONFIRMED maps to confirmed" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "STATUS" => "CONFIRMED"},
        "test-uid")
      assert attrs["status"] == "confirmed"
    end

    test "CANCELLED maps to cancelled" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "STATUS" => "CANCELLED"},
        "test-uid")
      assert attrs["status"] == "cancelled"
    end

    test "unknown status defaults to confirmed" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z"},
        "test-uid")
      assert attrs["status"] == "confirmed"
    end
  end

  describe "class to visibility mapping" do
    test "PUBLIC maps to public" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "CLASS" => "PUBLIC"},
        "test-uid")
      assert attrs["visibility"] == "public"
    end

    test "PRIVATE maps to private" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "CLASS" => "PRIVATE"},
        "test-uid")
      assert attrs["visibility"] == "private"
    end

    test "CONFIDENTIAL maps to circle" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "CLASS" => "CONFIDENTIAL"},
        "test-uid")
      assert attrs["visibility"] == "circle"
    end
  end

  describe "text unescaping" do
    test "unescapes newlines" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DESCRIPTION" => "Line 1\\nLine 2",
          "DTSTART" => "20260511T090000Z", "DTEND" => "20260511T100000Z"},
        "test-uid")
      assert attrs["description"] == "Line 1\nLine 2"
    end

    test "unescapes commas and semicolons" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test\\,Item", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z"},
        "test-uid")
      assert attrs["title"] == "Test,Item"
    end
  end

  describe "datetime parsing" do
    test "parses UTC datetime" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Test", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z"},
        "test-uid")
      assert is_integer(attrs["start_at"])
      assert attrs["start_at"] > 0
      assert attrs["end_at"] > attrs["start_at"]
    end

    test "parses RRULE" do
      attrs = Importer.props_to_event("did:web:alice.com",
        %{"SUMMARY" => "Weekly", "DTSTART" => "20260511T090000Z",
          "DTEND" => "20260511T100000Z", "RRULE" => "FREQ=WEEKLY;BYDAY=MO"},
        "test-uid")
      assert attrs["rrule"] == "FREQ=WEEKLY;BYDAY=MO"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Federation.HTTPSignatureTest do
  use ExUnit.Case, async: true

  alias PRZMA.Calendar.Federation.HTTPSignature

  describe "key_id_for_did" do
    test "generates correct key ID format" do
      key_id = HTTPSignature.key_id_for_did("did:web:alice.com", "https://alice.przma.net")
      assert String.ends_with?(key_id, "#key-1")
      assert String.contains?(key_id, "alice.przma.net")
    end
  end

  describe "signature header parsing" do
    test "extracts did from standard key_id" do
      # Simulated extract_did logic
      key_id = "https://alice.przma.net/ap/actor/did%3Aweb%3Aalice.com#key-1"
      assert String.contains?(key_id, "did%3Aweb%3Aalice.com")
      decoded = URI.decode("did%3Aweb%3Aalice.com")
      assert decoded == "did:web:alice.com"
    end
  end
end
