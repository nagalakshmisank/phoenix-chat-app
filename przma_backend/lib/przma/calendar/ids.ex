defmodule Przma.Calendar.Ids do
  @moduledoc """
  Every id, row key and time conversion the calendar service uses.

  Record ids may only contain A-Z a-z 0-9 _ - (Przma.Storage.DocKey), and
  "-" is used as the separator between parts, so no single part ever
  contains "-":

      calendar_id                       cal_<16 hex>   (default calendar: cald_<16 hex of the DID>)
      event_id                          Key.message_id/0 (17 digits of time + 6 hex)
      events row                        {calendar_id}-{event_id}
      shares row (user)                 {calendar_id}-u_{did_key}
      shares row (circle)               {calendar_id}-c_{circle_id}
      invites row                       {calendar_id}-{event_id}-{did_key}
      reminders row (system DID)        {fire_at 17 digits}-{did_key}-{event_id}-{minutes}
      circle_calendars row (system)     {circle_id}-{calendar_id}
      holidays row (system, public)     {region}-{yyyymmdd}-{slug}

  Times are stored as integer microseconds since the Unix epoch (UTC),
  like every other timestamp in this code base. The API takes and returns
  ISO-8601 strings.
  """

  alias Przma.Social.Key

  @system_did "did:przma-system:calendar"
  @system_gid "system"
  @minute_us 60_000_000

  @doc "The reserved DID that owns shared calendar tables (index, reminders, holidays)."
  def system_did, do: @system_did
  def system_gid, do: @system_gid

  def minute_us, do: @minute_us

  # ── ids ──────────────────────────────────────────────────────────────

  def calendar_id, do: "cal_" <> hex(8)

  @doc "Deterministic id of a user's default calendar, so creating it twice is harmless."
  def default_calendar_id(did) do
    "cald_" <> (:crypto.hash(:sha256, did) |> Base.encode16(case: :lower) |> binary_part(0, 16))
  end

  def event_id, do: Key.message_id()

  def event_row(calendar_id, event_id), do: calendar_id <> "-" <> event_id
  def event_prefix(calendar_id), do: calendar_id <> "-"

  def share_user_row(calendar_id, did), do: calendar_id <> "-u_" <> Key.did_key(did)
  def share_circle_row(calendar_id, circle_id), do: calendar_id <> "-c_" <> circle_id
  def share_circle_prefix(calendar_id), do: calendar_id <> "-c_"
  def share_prefix(calendar_id), do: calendar_id <> "-"

  def invite_row(calendar_id, event_id, did), do: calendar_id <> "-" <> event_id <> "-" <> Key.did_key(did)
  def invite_prefix(calendar_id, event_id), do: calendar_id <> "-" <> event_id <> "-"

  def circle_calendar_row(circle_id, calendar_id), do: circle_id <> "-" <> calendar_id
  def circle_calendar_prefix(circle_id), do: circle_id <> "-"

  def reminder_row(fire_at, did, event_id, minutes),
    do: pad(fire_at) <> "-" <> Key.did_key(did) <> "-" <> event_id <> "-" <> Integer.to_string(minutes)

  @doc "A client-supplied calendar / event / circle id: letters, digits and _ only."
  def valid?(id), do: Key.valid_id?(id)

  @doc "17-digit zero-padded microseconds, so string order = time order."
  def pad(us) when is_integer(us), do: us |> Integer.to_string() |> String.pad_leading(17, "0")

  # ── time ─────────────────────────────────────────────────────────────

  def now_us, do: System.os_time(:microsecond)

  @doc """
  "2026-11-03T17:00:00+05:30" -> {:ok, utc_microseconds, offset_minutes}.
  The offset is kept on the event so recurring events repeat at the same
  local time and on the right local weekday.
  """
  def parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(String.trim(iso)) do
      {:ok, dt, offset_seconds} -> {:ok, DateTime.to_unix(dt, :microsecond), div(offset_seconds, 60)}
      {:error, _} -> {:error, :invalid_time}
    end
  end

  def parse_time(_), do: {:error, :invalid_time}

  @doc "Microseconds -> ISO-8601 UTC string (nil stays nil)."
  def to_iso(nil), do: nil
  def to_iso(us) when is_integer(us), do: us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()

  @doc "Microseconds -> ISO-8601 string in the given UTC offset, e.g. 2026-11-03T17:00:00+05:30."
  def to_local_iso(nil, _offset_min), do: nil

  def to_local_iso(us, offset_min) when is_integer(us) do
    local = us + (offset_min || 0) * @minute_us
    naive = local |> DateTime.from_unix!(:microsecond) |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)
    NaiveDateTime.to_iso8601(naive) <> offset_string(offset_min || 0)
  end

  @doc "Readable local time for notification text: 03 Nov 2026, 17:00."
  def human(us, offset_min) do
    local = us + (offset_min || 0) * @minute_us
    dt = DateTime.from_unix!(local, :microsecond)
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    "#{two(dt.day)} #{Enum.at(months, dt.month - 1)} #{dt.year}, #{two(dt.hour)}:#{two(dt.minute)}"
  end

  @doc "UTC microseconds -> local Date (for holiday ranges)."
  def local_date(us, offset_min) do
    (us + (offset_min || 0) * @minute_us) |> DateTime.from_unix!(:microsecond) |> DateTime.to_date()
  end

  defp offset_string(min) do
    sign = if min < 0, do: "-", else: "+"
    abs_min = abs(min)
    sign <> two(div(abs_min, 60)) <> ":" <> two(rem(abs_min, 60))
  end

  defp two(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp hex(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)
end
