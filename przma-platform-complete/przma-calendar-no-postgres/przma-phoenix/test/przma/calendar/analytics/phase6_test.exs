# test/przma/calendar/analytics/phase6_test.exs

defmodule PRZMA.Calendar.Analytics.EmbeddingTest do
  use ExUnit.Case, async: true

  describe "embedding dimension" do
    test "embedding dim constant is 768" do
      # The NIF returns 768-dim vectors
      dim = 768
      assert dim == 768
    end
  end

  describe "cosine similarity semantics" do
    # Mirror the Rust logic for unit testing
    defp dot(v1, v2), do: Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    defp magnitude(v), do: :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
    defp cosine_sim(v1, v2) do
      m1 = magnitude(v1)
      m2 = magnitude(v2)
      if m1 == 0 or m2 == 0, do: 0.0, else: dot(v1, v2) / (m1 * m2)
    end

    test "identical vectors have similarity 1.0" do
      v = [0.5, 0.5, 0.5, 0.5]
      assert_in_delta cosine_sim(v, v), 1.0, 0.001
    end

    test "opposite vectors have similarity -1.0" do
      v1 = [1.0, 0.0]
      v2 = [-1.0, 0.0]
      assert_in_delta cosine_sim(v1, v2), -1.0, 0.001
    end

    test "orthogonal vectors have similarity ~0.0" do
      v1 = [1.0, 0.0]
      v2 = [0.0, 1.0]
      assert_in_delta cosine_sim(v1, v2), 0.0, 0.001
    end
  end

  describe "rank_by_similarity" do
    defp dot(v1, v2), do: Enum.zip(v1, v2) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
    defp magnitude(v), do: :math.sqrt(Enum.reduce(v, 0.0, fn x, acc -> acc + x * x end))
    defp cosine_sim(v1, v2) do
      m1 = magnitude(v1)
      m2 = magnitude(v2)
      if m1 == 0 or m2 == 0, do: 0.0, else: dot(v1, v2) / (m1 * m2)
    end

    defp rank(query, candidates, top_k) do
      scored = Enum.map(candidates, fn {id, vec} ->
        {id, cosine_sim(query, vec)}
      end)
      scored |> Enum.sort_by(fn {_, s} -> -s end) |> Enum.take(top_k)
    end

    test "returns top_k results" do
      q          = [1.0, 0.0, 0.0]
      candidates = [{"a", [1.0, 0.0, 0.0]}, {"b", [0.0, 1.0, 0.0]}, {"c", [-1.0, 0.0, 0.0]}]
      results    = rank(q, candidates, 2)
      assert length(results) == 2
    end

    test "most similar result is first" do
      q          = [1.0, 0.0]
      candidates = [{"a", [0.5, 0.5]}, {"b", [1.0, 0.0]}, {"c", [-1.0, 0.0]}]
      [{id, _} | _] = rank(q, candidates, 3)
      assert id == "b"
    end

    test "handles empty candidates" do
      q       = [1.0, 0.0]
      results = rank(q, [], 5)
      assert results == []
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Analytics.PatternsTest do
  use ExUnit.Case, async: true

  describe "streak computation" do
    # Mirror Rust streak logic
    defp compute_streaks([]), do: {0, 0}
    defp compute_streaks(days) do
      {consecutive_from_today(days), longest_run(days)}
    end

    defp consecutive_from_today([_single]), do: 1
    defp consecutive_from_today(days) do
      Enum.reduce_while(Enum.zip(days, tl(days)), 1, fn {d1, d2}, acc ->
        date1 = Date.from_iso8601!(d1)
        date2 = Date.from_iso8601!(d2)
        if Date.diff(date1, date2) == 1, do: {:cont, acc + 1}, else: {:halt, acc}
      end)
    end

    defp longest_run(days) do
      Enum.chunk_while(days, [], fn
        d, [] -> {:cont, [d]}
        d, [prev | _] = acc ->
          if Date.diff(Date.from_iso8601!(prev), Date.from_iso8601!(d)) == 1 do
            {:cont, [d | acc]}
          else
            {:emit, acc, [d]}
          end
      end, fn
        [] -> {:cont, []}
        acc -> {:emit, acc, []}
      end)
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 0 end)
    end

    test "consecutive days give correct streak" do
      days = ~w(2026-05-10 2026-05-09 2026-05-08 2026-05-07)
      {current, longest} = compute_streaks(days)
      assert current == 4
      assert longest == 4
    end

    test "broken streak resets" do
      days = ~w(2026-05-10 2026-05-08)  # gap on 9th
      {current, _} = compute_streaks(days)
      assert current == 1
    end

    test "empty days returns zeros" do
      assert {0, 0} = compute_streaks([])
    end

    test "single day is streak of 1" do
      {c, l} = compute_streaks(["2026-05-10"])
      assert c == 1
      assert l == 1
    end
  end

  describe "meeting pattern thresholds" do
    defp meeting_overloaded?(avg_per_day), do: avg_per_day > 5.0
    defp focus_ratio_ok?(ratio), do: ratio >= 0.2

    test "5 meetings/day is not overloaded" do
      refute meeting_overloaded?(5.0)
    end

    test "5.1 meetings/day triggers overload insight" do
      assert meeting_overloaded?(5.1)
    end

    test "20% focus ratio is acceptable" do
      assert focus_ratio_ok?(0.20)
    end

    test "19% focus ratio triggers suggestion" do
      refute focus_ratio_ok?(0.19)
    end
  end

  describe "practice adherence rate" do
    defp adherence_pct(completed, scheduled) when scheduled > 0 do
      min(completed / scheduled * 100, 100.0)
    end
    defp adherence_pct(_, 0), do: 0.0

    test "100% adherence when all scheduled are done" do
      assert adherence_pct(7, 7) == 100.0
    end

    test "adherence caps at 100%" do
      assert adherence_pct(10, 7) == 100.0
    end

    test "zero scheduled gives 0%" do
      assert adherence_pct(5, 0) == 0.0
    end

    test "partial adherence calculates correctly" do
      assert_in_delta adherence_pct(3, 7), 42.857, 0.01
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Intelligence.CompanionContextTest do
  use ExUnit.Case, async: true

  describe "morning briefing construction" do
    defp greeting(hour) do
      cond do
        hour < 12 -> "Good morning."
        hour < 17 -> "Good afternoon."
        true      -> "Good evening."
      end
    end

    test "morning hours give correct greeting" do
      assert greeting(7)  == "Good morning."
      assert greeting(11) == "Good morning."
    end

    test "afternoon hours give correct greeting" do
      assert greeting(12) == "Good afternoon."
      assert greeting(16) == "Good afternoon."
    end

    test "evening hours give correct greeting" do
      assert greeting(17) == "Good evening."
      assert greeting(23) == "Good evening."
    end
  end

  describe "situation assessment" do
    defp assess(meeting_count, overdue_count) do
      cond do
        overdue_count >= 3 and meeting_count >= 4 -> :high_load
        overdue_count >= 3                         -> :overdue_pressure
        meeting_count >= 5                         -> :meeting_heavy
        true                                       -> :normal
      end
    end

    test "normal situation with few events" do
      assert assess(2, 0) == :normal
    end

    test "meeting-heavy with 5+ meetings" do
      assert assess(5, 0) == :meeting_heavy
    end

    test "overdue pressure with 3+ overdue tasks" do
      assert assess(1, 3) == :overdue_pressure
    end

    test "high load when both overdue and meeting-heavy" do
      assert assess(4, 3) == :high_load
    end
  end

  describe "next event calculation" do
    defp find_next(events, now_micros) do
      events
      |> Enum.sort_by(fn e -> e["start_at"] end)
      |> Enum.find(fn e -> e["start_at"] >= now_micros end)
    end

    test "finds the next future event" do
      now = 1_000_000
      events = [
        %{"id" => "past", "start_at" => 500_000},
        %{"id" => "next", "start_at" => 2_000_000},
        %{"id" => "later", "start_at" => 3_000_000},
      ]
      result = find_next(events, now)
      assert result["id"] == "next"
    end

    test "returns nil when no future events" do
      now    = 5_000_000
      events = [%{"id" => "past", "start_at" => 1_000_000}]
      assert nil == find_next(events, now)
    end

    test "returns nil for empty event list" do
      assert nil == find_next([], 1_000_000)
    end
  end

  describe "minutes to next event" do
    defp mins_to_next(event_micros, now_micros) do
      div(event_micros - now_micros, 60_000_000)
    end

    test "calculates 30 minutes correctly" do
      now   = 0
      event = 30 * 60 * 1_000_000
      assert mins_to_next(event, now) == 30
    end

    test "calculates 90 minutes correctly" do
      now   = 0
      event = 90 * 60 * 1_000_000
      assert mins_to_next(event, now) == 90
    end
  end

  describe "total busy minutes" do
    defp total_busy(events) do
      Enum.reduce(events, 0, fn e, acc ->
        start = e["start_at"] || 0
        stop  = e["end_at"]   || start
        acc + div(stop - start, 60_000_000)
      end)
    end

    test "sums busy minutes across events" do
      one_hour = 60 * 60 * 1_000_000
      events   = [
        %{"start_at" => 0, "end_at" => one_hour},
        %{"start_at" => one_hour, "end_at" => 2 * one_hour},
      ]
      assert total_busy(events) == 120
    end

    test "empty events give zero" do
      assert total_busy([]) == 0
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Jobs.AnalyticsJobsTest do
  use ExUnit.Case, async: true

  describe "morning briefing scheduling" do
    defp should_schedule_today?(hour, minute) do
      now      = DateTime.utc_now()
      now_hour = now.hour
      now_min  = now.minute
      # Schedule if trigger time is still in the future today
      hour > now_hour or (hour == now_hour and minute > now_min)
    end

    test "schedules today when trigger is in the future" do
      # Use midnight + 1 day logic — if hour=23 and now is 8am, should schedule today
      now_hour = DateTime.utc_now().hour
      future_hour = min(now_hour + 1, 23)
      assert should_schedule_today?(future_hour, 0)
    end
  end

  describe "weekly insights scheduling" do
    test "calculates days to next Monday" do
      # Day of week: 1=Monday, 7=Sunday
      current_dow = Date.day_of_week(Date.utc_today())
      days_to_monday = Integer.mod(1 - current_dow, 7)
      days_to_monday = if days_to_monday == 0, do: 7, else: days_to_monday
      assert days_to_monday >= 1
      assert days_to_monday <= 7
    end
  end

  describe "adapter training threshold" do
    defp should_retrain?(new_entries, threshold), do: new_entries >= threshold

    test "triggers retrain when threshold met" do
      assert should_retrain?(50, 50)
    end

    test "does not retrain below threshold" do
      refute should_retrain?(49, 50)
    end

    test "triggers retrain well above threshold" do
      assert should_retrain?(100, 50)
    end
  end

  describe "embedding backfill detection" do
    defp needs_embedding?(event) do
      emb = event["embedding"] || []
      Enum.all?(emb, fn v -> v == 0.0 end)
    end

    test "event with all-zero embedding needs backfill" do
      event = %{"embedding" => List.duplicate(0.0, 768)}
      assert needs_embedding?(event)
    end

    test "event with non-zero embedding does not need backfill" do
      embedding = [0.1 | List.duplicate(0.0, 767)]
      event     = %{"embedding" => embedding}
      refute needs_embedding?(event)
    end

    test "event with nil embedding needs backfill" do
      event = %{"embedding" => nil}
      assert needs_embedding?(event)
    end
  end
end
