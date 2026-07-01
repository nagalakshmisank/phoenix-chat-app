# lib/przma/calendar/federation/ical.ex
#
# iCal export and CalDAV bridge for PRZMA Calendar.
# Handles RFC 5545 iCalendar export and RFC 4791 CalDAV sync.

defmodule PRZMA.Calendar.Federation.ICal do
  alias PRZMA.Calendar.{NIF, Events, Tasks}
  alias PRZMA.Calendar.Federation.ICal.Importer

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── EXPORT ───────────────────────────────────────────────────────────────

  @doc """
  Export a calendar namespace as an RFC 5545 iCal string.
  Options: space, start, end, include_tasks, calendar_name, timezone
  """
  def export(did, opts \\ []) do
    space     = opts[:space]        || "core"
    start_dt  = opts[:start]
    end_dt    = opts[:end]
    cal_name  = opts[:calendar_name] || display_name(did)
    timezone  = opts[:timezone]      || "UTC"
    inc_tasks = opts[:include_tasks] != false

    query = %{
      space:         space,
      start_micros:  start_dt && DateTime.to_unix(start_dt, :microsecond),
      end_micros:    end_dt   && DateTime.to_unix(end_dt,   :microsecond),
      include_tasks: inc_tasks,
      timezone:      timezone,
    } |> Map.reject(fn {_, v} -> is_nil(v) end)

    case NIF.export_ical(@base_path, did, Jason.encode!(query), cal_name) do
      {:ok, ical_str} -> {:ok, ical_str}
      {:error, msg}   -> {:error, msg}
    end
  end

  # ── IMPORT (CalDAV PUT) ──────────────────────────────────────────────────

  @doc """
  Import a single VEVENT from an iCal PUT request (CalDAV).
  Creates or updates the corresponding CalendarEvent.
  """
  def import_vevent(did, ical_str, ical_uid) do
    case NIF.parse_ical_event(@base_path, ical_str) do
      {:ok, props_json} ->
        props = Jason.decode!(props_json)
        Importer.props_to_event(did, props, ical_uid)
        |> then(fn attrs -> Events.create(did, attrs) end)

      {:error, msg} ->
        {:error, msg}
    end
  end

  # ── CALENDAR LISTING (CalDAV PROPFIND) ───────────────────────────────────

  @doc """
  List available calendars for a DID.
  Returns calendar metadata for CalDAV PROPFIND response.
  """
  def list_calendars(did) do
    calendars = [
      %{
        id:          "personal",
        name:        "Personal",
        description: "Personal calendar",
        color:       "#1A2744",
        supported:   ["VEVENT", "VTODO"],
      }
    ]

    # Add circle calendars
    circle_cals = did
      |> PRZMA.Identity.list_circles_for_did()
      |> Enum.map(fn m ->
          %{
            id:          "circle-#{m.circle_did}",
            name:        "Circle: #{m.circle_did}",
            description: "Circle calendar",
            color:       "#1B6B6B",
            supported:   ["VEVENT"],
          }
        end)

    {:ok, calendars ++ circle_cals}
  end

  # ── CALENDAR SYNC TOKEN ──────────────────────────────────────────────────

  @doc "Generate a sync token for CalDAV REPORT responses"
  def sync_token(did, calendar_id) do
    ts = System.os_time(:second)
    :crypto.hash(:sha256, "#{did}:#{calendar_id}:#{ts}")
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp display_name(did) do
    did |> String.split(":") |> List.last() |> String.capitalize()
  end
end

# ─── ICAL IMPORTER ────────────────────────────────────────────────────────────

defmodule PRZMA.Calendar.Federation.ICal.Importer do
  @doc "Convert parsed iCal props map to CalendarEvent attributes"
  def props_to_event(did, props, ical_uid) do
    start_at = parse_ical_dt(props["DTSTART"])
    end_at   = parse_ical_dt(props["DTEND"] || props["DTSTART"])
    duration = parse_duration(props["DURATION"])

    end_at = end_at || (start_at && start_at + (duration || 3_600_000_000))

    category = case props["X-PRZMA-CATEGORY"] do
      nil -> "EVENT"
      cat -> cat
    end

    %{
      "title"        => unescape(props["SUMMARY"] || ""),
      "description"  => unescape(props["DESCRIPTION"] || ""),
      "category"     => category,
      "start_at"     => start_at,
      "end_at"       => end_at,
      "all_day"      => String.contains?(props["DTSTART"] || "", "DATE:") and
                        not String.contains?(props["DTSTART"] || "", "T"),
      "timezone"     => extract_tzid(props["DTSTART"] || ""),
      "rrule"        => props["RRULE"],
      "status"       => ical_status_to_przma(props["STATUS"]),
      "visibility"   => ical_class_to_visibility(props["CLASS"]),
      "ical_uid"     => ical_uid || props["UID"] || "",
      "external_id"  => props["UID"],
      "space"        => "core",
      "did"          => did,
    }
  end

  defp parse_ical_dt(nil), do: nil
  defp parse_ical_dt(str) do
    # Handle TZID=America/Chicago:20260511T090000
    value = str |> String.split(":") |> List.last()
    case Regex.run(~r/(\d{8}T\d{6})(Z?)/, value) do
      [_, dt_str, "Z"] ->
        NaiveDateTime.from_iso8601!(
          "#{String.slice(dt_str, 0, 4)}-#{String.slice(dt_str, 4, 2)}-" <>
          "#{String.slice(dt_str, 6, 2)}T#{String.slice(dt_str, 9, 2)}:" <>
          "#{String.slice(dt_str, 11, 2)}:#{String.slice(dt_str, 13, 2)}")
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix(:microsecond)

      [_, dt_str, ""] ->
        NaiveDateTime.from_iso8601!(
          "#{String.slice(dt_str, 0, 4)}-#{String.slice(dt_str, 4, 2)}-" <>
          "#{String.slice(dt_str, 6, 2)}T#{String.slice(dt_str, 9, 2)}:" <>
          "#{String.slice(dt_str, 11, 2)}:#{String.slice(dt_str, 13, 2)}")
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.to_unix(:microsecond)

      _ -> nil
    end
  end

  defp parse_duration(nil), do: nil
  defp parse_duration(str) do
    # PT1H30M → 5400 seconds → 5_400_000_000 microseconds
    case Regex.run(~r/P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?/, str) do
      [_, d, h, m] ->
        days  = String.to_integer(d || "0")
        hours = String.to_integer(h || "0")
        mins  = String.to_integer(m || "0")
        (days * 86400 + hours * 3600 + mins * 60) * 1_000_000
      _ -> nil
    end
  end

  defp extract_tzid(str) do
    case Regex.run(~r/TZID=([^:]+):/, str) do
      [_, tz] -> tz
      _       -> "UTC"
    end
  end

  defp ical_status_to_przma("CONFIRMED"), do: "confirmed"
  defp ical_status_to_przma("TENTATIVE"), do: "tentative"
  defp ical_status_to_przma("CANCELLED"), do: "cancelled"
  defp ical_status_to_przma(_),           do: "confirmed"

  defp ical_class_to_visibility("PUBLIC"),       do: "public"
  defp ical_class_to_visibility("PRIVATE"),      do: "private"
  defp ical_class_to_visibility("CONFIDENTIAL"), do: "circle"
  defp ical_class_to_visibility(_),              do: "private"

  defp unescape(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end
end
