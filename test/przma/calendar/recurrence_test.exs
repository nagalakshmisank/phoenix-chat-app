defmodule Przma.Calendar.RecurrenceTest do
  use ExUnit.Case, async: true

  alias Przma.Calendar.{Ids, Recurrence}

  defp t(iso) do
    {:ok, us, _} = Ids.parse_time(iso)
    us
  end

  defp event(start_iso, end_iso, rule) do
    {:ok, s, offset} = Ids.parse_time(start_iso)
    {:ok, e, _} = Ids.parse_time(end_iso)
    {:ok, rule} = Recurrence.normalize(rule)
    %{"starts_at" => s, "ends_at" => e, "utc_offset_min" => offset, "recurrence" => rule}
  end

  defp local(list), do: Enum.map(list, &Ids.to_local_iso(&1, 330))

  test "one-off event inside and outside the range" do
    ev = event("2026-11-03T17:00:00+05:30", "2026-11-03T17:30:00+05:30", nil)
    assert Recurrence.occurrences(ev, t("2026-11-01T00:00:00+05:30"), t("2026-11-08T00:00:00+05:30")) == [ev["starts_at"]]
    assert Recurrence.occurrences(ev, t("2026-11-04T00:00:00+05:30"), t("2026-11-08T00:00:00+05:30")) == []
  end

  test "weekly on Monday and Wednesday keeps local time and weekday" do
    ev = event("2026-11-02T09:00:00+05:30", "2026-11-02T10:00:00+05:30", %{freq: "weekly", by_day: ["MO", "WE"]})

    assert local(Recurrence.occurrences(ev, t("2026-11-01T00:00:00+05:30"), t("2026-11-15T00:00:00+05:30"))) == [
             "2026-11-02T09:00:00+05:30",
             "2026-11-04T09:00:00+05:30",
             "2026-11-09T09:00:00+05:30",
             "2026-11-11T09:00:00+05:30"
           ]
  end

  test "count and exdates" do
    {:ok, skip, _} = Ids.parse_time("2026-11-04T09:00:00+05:30")

    ev =
      event("2026-11-03T09:00:00+05:30", "2026-11-03T09:30:00+05:30", %{
        freq: "daily",
        count: 4,
        exdates: ["2026-11-04T09:00:00+05:30"]
      })

    occ = Recurrence.occurrences(ev, t("2026-11-01T00:00:00+05:30"), t("2026-12-01T00:00:00+05:30"))
    assert length(occ) == 3
    refute skip in occ
  end

  test "monthly on the 31st skips short months" do
    ev = event("2026-01-31T10:00:00+05:30", "2026-01-31T11:00:00+05:30", %{freq: "monthly"})

    assert local(Recurrence.occurrences(ev, t("2026-01-01T00:00:00+05:30"), t("2026-06-01T00:00:00+05:30"))) == [
             "2026-01-31T10:00:00+05:30",
             "2026-03-31T10:00:00+05:30",
             "2026-05-31T10:00:00+05:30"
           ]
  end

  test "yearly birthday, until, next_after and occurs?" do
    ev =
      event("2026-03-12T00:00:00+05:30", "2026-03-12T23:59:00+05:30", %{
        freq: "yearly",
        until: "2028-12-31T00:00:00+05:30"
      })

    occ = Recurrence.occurrences(ev, t("2026-01-01T00:00:00+05:30"), t("2035-01-01T00:00:00+05:30"))
    assert local(occ) == ["2026-03-12T00:00:00+05:30", "2027-03-12T00:00:00+05:30", "2028-03-12T00:00:00+05:30"]
    assert Recurrence.next_after(ev, Enum.at(occ, 0)) == Enum.at(occ, 1)
    assert Recurrence.occurs?(ev, Enum.at(occ, 2))
    refute Recurrence.occurs?(ev, Enum.at(occ, 2) + 1)
  end

  test "an event that started before the range but is still running is included" do
    ev = event("2026-11-03T22:00:00+05:30", "2026-11-04T02:00:00+05:30", nil)
    assert Recurrence.occurrences(ev, t("2026-11-04T00:00:00+05:30"), t("2026-11-05T00:00:00+05:30")) == [ev["starts_at"]]
  end

  test "invalid rules are rejected" do
    assert {:error, :invalid_recurrence_freq} = Recurrence.normalize(%{freq: "hourly"})
    assert {:error, :invalid_recurrence_by_day} = Recurrence.normalize(%{freq: "weekly", by_day: ["XX"]})
    assert {:error, :invalid_recurrence_interval} = Recurrence.normalize(%{freq: "daily", interval: 0})
  end
end
