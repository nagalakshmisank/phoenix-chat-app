defmodule Przma.Calendar.Recurrence do
  @moduledoc """
  Repeating events, kept as ONE stored row and expanded when read.

  Rule (stored in the event's "recurrence" field, string keys):

      "freq"     "daily" | "weekly" | "monthly" | "yearly"   (required)
      "interval" every N days/weeks/months/years             (default 1)
      "by_day"   weekly only: ["MO", "WE", "FR"]             (default: the start's weekday)
      "count"    stop after N occurrences                    (optional)
      "until"    stop after this time, microseconds           (optional)
      "exdates"  skipped occurrence starts, microseconds      (optional)

  Occurrences are computed in the event's local time (its "utc_offset_min"),
  so "every Monday 09:00 +05:30" stays on Monday 09:00 local. Offsets are
  fixed per event: correct for India (no daylight saving). Zones with
  daylight saving need a time-zone database (tzdata) — not added yet.

  Pure functions only: no storage, safe to unit-test.
  """

  alias Przma.Calendar.Ids

  @freqs ~w(daily weekly monthly yearly)
  @days ~w(MO TU WE TH FR SA SU)
  # Upper bound on generated periods, so a rule that never matches
  # (e.g. day 31 every 12 months starting in a 30-day month) still ends.
  @max_steps 20_000
  @max_results 2_000

  def freqs, do: @freqs
  def days, do: @days

  @doc """
  Validates and normalises client input (atom or string keys, times as
  ISO strings or microseconds). Returns {:ok, rule | nil}.
  """
  def normalize(nil), do: {:ok, nil}

  def normalize(rule) when is_map(rule) do
    rule = Map.new(rule, fn {k, v} -> {to_string(k), v} end)
    freq = rule["freq"] && String.downcase(to_string(rule["freq"]))
    interval = rule["interval"] || 1
    by_day = rule["by_day"] && Enum.map(rule["by_day"], &String.upcase(to_string(&1)))

    with :ok <- check(freq in @freqs, :invalid_recurrence_freq),
         :ok <- check(is_integer(interval) and interval in 1..99, :invalid_recurrence_interval),
         :ok <- check(is_nil(by_day) or (by_day != [] and Enum.all?(by_day, &(&1 in @days))), :invalid_recurrence_by_day),
         :ok <- check(is_nil(rule["count"]) or (is_integer(rule["count"]) and rule["count"] in 1..1000), :invalid_recurrence_count),
         {:ok, until} <- time_or_nil(rule["until"]),
         {:ok, exdates} <- times(rule["exdates"] || []) do
      {:ok,
       %{
         "freq" => freq,
         "interval" => interval,
         "by_day" => if(freq == "weekly", do: by_day, else: nil),
         "count" => rule["count"],
         "until" => until,
         "exdates" => exdates
       }}
    end
  end

  def normalize(_), do: {:error, :invalid_recurrence}

  @doc "Event duration in microseconds (0 when it has no end)."
  def duration(%{"starts_at" => s, "ends_at" => e}) when is_integer(s) and is_integer(e) and e >= s, do: e - s
  def duration(_), do: 0

  @doc """
  Start times (microseconds) of the occurrences that overlap [from, to).
  A one-off event returns [starts_at] or [].
  """
  def occurrences(%{"starts_at" => s} = event, from, to) when is_integer(s) do
    d = duration(event)

    case event["recurrence"] do
      nil ->
        if overlaps?(s, d, from, to), do: [s], else: []

      rule ->
        event
        |> stream(rule)
        |> Stream.take_while(&(&1 < to))
        |> Stream.filter(&overlaps?(&1, d, from, to))
        |> Enum.take(@max_results)
    end
  end

  @doc "First occurrence starting strictly after `after_us`, or nil."
  def next_after(%{"starts_at" => s} = event, after_us) do
    case event["recurrence"] do
      nil -> if s > after_us, do: s, else: nil
      rule -> event |> stream(rule) |> Enum.find(&(&1 > after_us))
    end
  end

  @doc "Whether `occ_us` is still a valid occurrence start of this event."
  def occurs?(%{"starts_at" => s} = event, occ_us) do
    case event["recurrence"] do
      nil -> s == occ_us
      rule -> event |> stream(rule) |> Enum.find(&(&1 >= occ_us)) == occ_us
    end
  end

  # ── generation ───────────────────────────────────────────────────────

  # All occurrence starts in time order, after count / until / exdates.
  defp stream(%{"starts_at" => s} = event, rule) do
    offset_us = (event["utc_offset_min"] || 0) * Ids.minute_us()
    local0 = to_naive(s + offset_us)
    excluded = MapSet.new(rule["exdates"] || [])

    0..@max_steps
    |> Stream.flat_map(&step(rule["freq"], local0, rule, &1))
    |> Stream.map(&(from_naive(&1) - offset_us))
    |> maybe_take(rule["count"])
    |> Stream.take_while(&(is_nil(rule["until"]) or &1 <= rule["until"]))
    |> Stream.reject(&MapSet.member?(excluded, &1))
  end

  defp maybe_take(stream, nil), do: stream
  defp maybe_take(stream, count), do: Stream.take(stream, count)

  defp step("daily", local0, rule, k), do: [NaiveDateTime.add(local0, k * interval(rule) * 86_400, :second)]

  defp step("weekly", local0, rule, k) do
    date = NaiveDateTime.to_date(local0)
    time = NaiveDateTime.to_time(local0)
    week_start = Date.add(date, 1 - Date.day_of_week(date))
    base = Date.add(week_start, 7 * interval(rule) * k)
    wanted = rule["by_day"] || [Enum.at(@days, Date.day_of_week(date) - 1)]

    wanted
    |> Enum.map(fn day -> Enum.find_index(@days, &(&1 == day)) end)
    |> Enum.sort()
    |> Enum.uniq()
    |> Enum.map(&NaiveDateTime.new!(Date.add(base, &1), time))
    |> Enum.filter(&(NaiveDateTime.compare(&1, local0) != :lt))
  end

  defp step("monthly", local0, rule, k) do
    total = local0.year * 12 + (local0.month - 1) + k * interval(rule)
    on_date(div(total, 12), rem(total, 12) + 1, local0)
  end

  defp step("yearly", local0, rule, k), do: on_date(local0.year + k * interval(rule), local0.month, local0)

  # Same day-of-month and time; a month without that day is skipped
  # (31st in April, 29 Feb in a non-leap year).
  defp on_date(year, month, local0) do
    case Date.new(year, month, local0.day) do
      {:ok, date} -> [NaiveDateTime.new!(date, NaiveDateTime.to_time(local0))]
      {:error, _} -> []
    end
  end

  defp interval(rule), do: rule["interval"] || 1

  defp overlaps?(start, 0, from, to), do: start >= from and start < to
  defp overlaps?(start, d, from, to), do: start < to and start + d > from

  defp to_naive(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive()
  defp from_naive(naive), do: naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)

  # ── input helpers ────────────────────────────────────────────────────

  defp time_or_nil(nil), do: {:ok, nil}
  defp time_or_nil(us) when is_integer(us), do: {:ok, us}

  defp time_or_nil(iso) do
    case Ids.parse_time(iso) do
      {:ok, us, _} -> {:ok, us}
      err -> err
    end
  end

  defp times(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case time_or_nil(item) do
        {:ok, us} when is_integer(us) -> {:cont, {:ok, [us | acc]}}
        _ -> {:halt, {:error, :invalid_recurrence_exdates}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp times(_), do: {:error, :invalid_recurrence_exdates}

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}
end
