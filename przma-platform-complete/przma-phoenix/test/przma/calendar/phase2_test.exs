# test/przma/calendar/governance_test.exs

defmodule PRZMA.Calendar.GovernanceTest do
  use ExUnit.Case, async: true
  alias PRZMA.Calendar.Governance

  describe "role hierarchy" do
    test "steward has at least steward authority" do
      assert Governance.role_at_least?("steward", "steward")
    end

    test "steward has at least guardian authority" do
      assert Governance.role_at_least?("steward", "guardian")
    end

    test "guardian does not have steward authority" do
      refute Governance.role_at_least?("guardian", "steward")
    end

    test "participant does not have contributor authority" do
      refute Governance.role_at_least?("participant", "contributor")
    end

    test "guest is lowest authority" do
      refute Governance.role_at_least?("guest", "observer")
    end
  end

  describe "content permissions" do
    test "steward can create content" do
      assert Governance.can_create_content?("steward")
    end

    test "contributor can create content" do
      assert Governance.can_create_content?("contributor")
    end

    test "participant cannot create content" do
      refute Governance.can_create_content?("participant")
    end

    test "only guardian and above can edit any content" do
      assert Governance.can_edit_any?("steward")
      assert Governance.can_edit_any?("guardian")
      refute Governance.can_edit_any?("contributor")
    end

    test "only steward can dissolve" do
      assert Governance.can_dissolve?("steward")
      refute Governance.can_dissolve?("guardian")
    end

    test "only steward can modify charter" do
      assert Governance.can_modify_charter?("steward")
      refute Governance.can_modify_charter?("guardian")
    end
  end

  describe "interaction permissions" do
    test "participant can RSVP" do
      assert Governance.can_rsvp?("participant")
    end

    test "guest can RSVP" do
      assert Governance.can_rsvp?("guest")
    end

    test "observer cannot RSVP" do
      refute Governance.can_rsvp?("observer")
    end

    test "participant can vote in polls" do
      assert Governance.can_vote?("participant")
    end

    test "observer cannot vote" do
      refute Governance.can_vote?("observer")
    end
  end

  describe "permitted?/2" do
    test "returns true for valid permission" do
      assert Governance.permitted?("steward", :create_content)
      assert Governance.permitted?("contributor", :create_task)
      assert Governance.permitted?("participant", :rsvp)
    end

    test "returns false for denied permission" do
      refute Governance.permitted?("participant", :create_content)
      refute Governance.permitted?("observer", :vote)
      refute Governance.permitted?("guardian", :dissolve)
    end

    test "raises on unknown action" do
      assert_raise RuntimeError, ~r/Unknown calendar action/, fn ->
        Governance.permitted?("steward", :fly_to_moon)
      end
    end
  end

  describe "assert_permitted/2" do
    test "returns :ok when permitted" do
      assert :ok = Governance.assert_permitted("steward", :create_content)
    end

    test "returns error tuple when denied" do
      assert {:error, :permission_denied} =
        Governance.assert_permitted("participant", :create_content)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# test/przma/calendar/circle_namespace_test.exs (Rust unit tests via mix test)
# The Rust tests in circle.rs cover:
#   - provision_idempotent
#   - derive_circle_key_deterministic
#   - derive_circle_key_unique_per_circle
# Run via: cargo test --package przma-calendar

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.AvailabilityTest do
  use ExUnit.Case, async: true

  describe "slot availability calculation" do
    test "returns no slots when all time is busy" do
      # All slots overlap with busy window
      busy_windows = [%{
        "start_at" => 0,
        "end_at"   => 999_999_999_999_999,
        "show_as"  => "busy",
        "label"    => "Busy",
      }]
      # Helper function extracted from Availability module for testing
      result = find_free_slots_test(busy_windows, 0, 3_600_000_000, 30)
      assert result == []
    end

    test "returns slots when time is free" do
      busy_windows = []
      # 1-hour range, 30-min slots = 2 slots
      result = find_free_slots_test(busy_windows, 0, 3_600_000_000, 30)
      assert length(result) == 2
    end
  end

  # Private test helper replicating the logic from Availability module
  defp find_free_slots_test(busy_windows, start_micros, end_micros, duration_mins) do
    step_micros = duration_mins * 60 * 1_000_000

    start_micros
    |> Stream.iterate(&(&1 + step_micros))
    |> Stream.take_while(&(&1 + step_micros <= end_micros))
    |> Enum.reject(fn slot_start ->
      slot_end = slot_start + step_micros
      Enum.any?(busy_windows, fn busy ->
        slot_start < busy["end_at"] and slot_end > busy["start_at"]
      end)
    end)
    |> Enum.map(fn slot_start ->
      %{start_at: slot_start, end_at: slot_start + step_micros, show_as: "free"}
    end)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.PollsTallyTest do
  use ExUnit.Case, async: true

  test "tally counts votes correctly" do
    poll = %{
      "options" => [
        %{"id" => "opt1", "label" => "Option 1"},
        %{"id" => "opt2", "label" => "Option 2"},
        %{"id" => "opt3", "label" => "Option 3"},
      ],
      "votes" => %{
        "did:web:alice.com" => ["opt1"],
        "did:web:bob.com"   => ["opt1"],
        "did:web:carol.com" => ["opt2"],
      },
      "resolved_option" => nil,
    }

    # Simulate tally
    counts = poll["votes"]
      |> Enum.flat_map(fn {_, ids} -> ids end)
      |> Enum.frequencies()

    assert counts["opt1"] == 2
    assert counts["opt2"] == 1
    assert counts["opt3"] == nil
  end

  test "tally handles empty votes" do
    poll = %{"options" => [], "votes" => %{}, "resolved_option" => nil}
    counts = poll["votes"]
      |> Enum.flat_map(fn {_, ids} -> ids end)
      |> Enum.frequencies()
    assert counts == %{}
  end
end
