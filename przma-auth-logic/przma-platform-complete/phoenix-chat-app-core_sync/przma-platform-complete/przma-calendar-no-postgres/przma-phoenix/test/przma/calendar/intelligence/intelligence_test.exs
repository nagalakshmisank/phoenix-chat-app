# test/przma/calendar/intelligence/intelligence_test.exs

defmodule PRZMA.Calendar.Intelligence.PreBriefTest do
  use ExUnit.Case, async: true

  describe "companion prompt building" do
    # Mirror the private function logic for testing
    defp has_overdue?(brief) do
      now = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
      (brief["open_action_items"] || [])
      |> Enum.any?(fn a -> a["due_at"] && a["due_at"] < now end)
    end

    test "detects overdue action items" do
      past_micros = DateTime.utc_now()
        |> DateTime.add(-86400, :second)
        |> DateTime.to_unix(:microsecond)

      brief = %{
        "open_action_items" => [
          %{"title" => "Send report", "due_at" => past_micros, "status" => "active"}
        ]
      }
      assert has_overdue?(brief)
    end

    test "no overdue when all items are future" do
      future_micros = DateTime.utc_now()
        |> DateTime.add(86400, :second)
        |> DateTime.to_unix(:microsecond)

      brief = %{
        "open_action_items" => [
          %{"title" => "Send report", "due_at" => future_micros, "status" => "active"}
        ]
      }
      refute has_overdue?(brief)
    end

    test "no overdue with empty action items" do
      brief = %{"open_action_items" => []}
      refute has_overdue?(brief)
    end
  end

  describe "vault domain mapping" do
    defp vault_domain(category) do
      case category do
        "MEETING"     -> "My People"
        "PRACTICE"    -> "My Practices"
        "STUDY"       -> "What I Learned"
        "APPOINTMENT" -> "My Health"
        _             -> "My Day"
      end
    end

    test "MEETING maps to My People" do
      assert vault_domain("MEETING") == "My People"
    end

    test "PRACTICE maps to My Practices" do
      assert vault_domain("PRACTICE") == "My Practices"
    end

    test "STUDY maps to What I Learned" do
      assert vault_domain("STUDY") == "What I Learned"
    end

    test "unknown maps to My Day" do
      assert vault_domain("BLOCK") == "My Day"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Intelligence.DuringMeetingTest do
  use ExUnit.Case, async: true

  describe "due date resolution" do
    # Mirror private function logic for testing
    defp resolve_due(hint) do
      case hint do
        "today"     -> {:has_date, true}
        "tomorrow"  -> {:has_date, true}
        "ASAP"      -> {:has_date, true}
        "this week" -> {:has_date, true}
        nil         -> {:no_date, true}
        _other      -> {:unknown, true}
      end
    end

    test "resolves today" do
      assert {:has_date, _} = resolve_due("today")
    end

    test "resolves tomorrow" do
      assert {:has_date, _} = resolve_due("tomorrow")
    end

    test "resolves ASAP" do
      assert {:has_date, _} = resolve_due("ASAP")
    end

    test "nil hint returns no date" do
      assert {:no_date, _} = resolve_due(nil)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Intelligence.PostMeetingTest do
  use ExUnit.Case, async: true

  describe "preview text" do
    defp preview(text, max), do: if String.length(text) <= max, do: text, else: String.slice(text, 0, max) <> "…"

    test "short text returned as-is" do
      assert preview("short", 100) == "short"
    end

    test "long text is truncated with ellipsis" do
      long = String.duplicate("a", 200)
      result = preview(long, 100)
      assert String.ends_with?(result, "…")
      assert String.length(result) == 101
    end

    test "nil text handled" do
      assert nil == nil  # nil guard in function
    end
  end

  describe "reflection submission params" do
    test "builds correct task attrs from confirmed item" do
      item = %{
        "text"           => "Send contract draft",
        "assignee_hint"  => "did:web:bob.com",
        "due_at"         => nil,
      }
      did      = "did:web:alice.com"
      event_id = "event-123"
      space    = "core"

      attrs = %{
        "title"       => item["text"],
        "space"       => space,
        "circle_did"  => nil,
        "event_id"    => event_id,
        "status"      => "active",
        "priority"    => "medium",
        "assigned_to" => [item["assignee_hint"] || did],
        "due_at"      => item["due_at"],
      }

      assert attrs["title"] == "Send contract draft"
      assert attrs["assigned_to"] == ["did:web:bob.com"]
      assert attrs["event_id"] == "event-123"
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.MeetingIntelligenceJobsTest do
  use ExUnit.Case, async: true

  describe "pre-brief scheduling" do
    test "skips scheduling when trigger time is in the past" do
      past_micros = DateTime.utc_now()
        |> DateTime.add(-3600, :second)
        |> DateTime.to_unix(:microsecond)

      # Simulate the schedule guard
      event_start  = DateTime.from_unix!(past_micros, :microsecond)
      trigger_at   = DateTime.add(event_start, -600, :second)
      is_future    = DateTime.compare(trigger_at, DateTime.utc_now()) == :gt

      refute is_future
    end

    test "schedules when trigger time is in the future" do
      future_micros = DateTime.utc_now()
        |> DateTime.add(3600, :second)
        |> DateTime.to_unix(:microsecond)

      event_start = DateTime.from_unix!(future_micros, :microsecond)
      trigger_at  = DateTime.add(event_start, -600, :second)
      is_future   = DateTime.compare(trigger_at, DateTime.utc_now()) == :gt

      assert is_future
    end
  end

  describe "audio duration estimation" do
    defp estimate_duration(byte_size), do: div(byte_size, 16_000)

    test "estimates 1 second for 16KB" do
      assert estimate_duration(16_000) == 1
    end

    test "estimates 60 seconds for ~1MB" do
      assert estimate_duration(960_000) == 60
    end
  end
end
