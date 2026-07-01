# lib/przma/calendar/availability.ex

defmodule PRZMA.Calendar.Availability do
  alias PRZMA.Calendar.{NIF, Events}
  alias PRZMAWeb.Endpoint

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── WINDOWS ──────────────────────────────────────────────────────────────────

  def list_windows(did, start_dt, end_dt) do
    query = %{
      space:        "core",
      start_micros: DateTime.to_unix(start_dt, :microsecond),
      end_micros:   DateTime.to_unix(end_dt, :microsecond),
      limit:        500,
    }
    case NIF.list_events(@base_path, did, Jason.encode!(query)) do
      {:ok, json}   -> {:ok, Jason.decode!(json)}
      {:error, msg} -> {:error, msg}
    end
  end

  def set_windows(did, windows) when is_list(windows) do
    Enum.each(windows, fn window ->
      w = window
        |> Map.put_new("id", generate_id(did))
        |> Map.put("did", did)
        |> Map.put_new("created_at", now_micros())
        |> Map.put("updated_at", now_micros())
      NIF.create_event(@base_path, did, Jason.encode!(w))
    end)
    broadcast_availability_updated(did)
    :ok
  end

  # ── FREE/BUSY ────────────────────────────────────────────────────────────────

  @doc """
  Compute free/busy for target_did, requested by requester_did.
  Returns merged busy windows — show_as label only, never event details.
  Requires requester to have a valid cross-DID permission grant or circle membership.
  """
  def freebusy(target_did, requester_did, start_dt, end_dt) do
    with :ok <- verify_freebusy_access(target_did, requester_did) do
      start_micros = DateTime.to_unix(start_dt, :microsecond)
      end_micros   = DateTime.to_unix(end_dt, :microsecond)

      # Get confirmed busy events
      opts = [space: "core", start_micros: start_micros,
              end_micros: end_micros, status: "confirmed", limit: 500]

      case Events.list(target_did, opts) do
        {:ok, events} ->
          slots = events
            |> Enum.filter(fn e -> e["busy_status"] == "busy" end)
            |> Enum.map(fn e -> %{
                start_at: e["start_at"],
                end_at:   e["end_at"],
                show_as:  "busy",
                label:    "Busy",      # never expose event title
              }
            end)
            |> merge_overlapping()
          {:ok, slots}

        {:error, msg} -> {:error, msg}
      end
    end
  end

  # ── BOOKING LINKS ─────────────────────────────────────────────────────────────

  def create_booking_link(did, attrs) do
    link = attrs
      |> Map.put_new("id", generate_link_id())
      |> Map.put("did", did)
      |> Map.put_new("is_active", true)
      |> Map.put_new("duration_mins", 30)
      |> Map.put_new("min_notice_mins", 60)
      |> Map.put_new("buffer_mins", 0)
      |> Map.put_new("questions", [])
      |> Map.put_new("confirmation_msg", "Your booking is confirmed.")
      |> Map.put_new("created_at", now_micros())
      |> Map.put("updated_at", now_micros())

    # Store in booking_links Lance table (via availability NIF path in Phase 2)
    # For now: store as a special event in core namespace
    PRZMA.Repo.insert_booking_link(link)
    {:ok, link}
  end

  def get_booking_link(link_id) do
    case PRZMA.Repo.get_booking_link(link_id) do
      nil  -> {:error, :not_found}
      link -> {:ok, link}
    end
  end

  def list_booking_links(did) do
    {:ok, PRZMA.Repo.list_booking_links(did)}
  end

  def available_slots(link_id, start_dt, end_dt) do
    with {:ok, link} <- get_booking_link(link_id) do
      did     = link["did"]
      dur     = link["duration_mins"]
      buf     = link["buffer_mins"] || 0
      notice  = link["min_notice_mins"] || 60
      step    = 30  # 30-minute slot grid

      with {:ok, busy} <- freebusy(did, did, start_dt, end_dt) do
        now = DateTime.utc_now()

        slots =
          start_dt
          |> Stream.iterate(&DateTime.add(&1, step * 60, :second))
          |> Stream.take_while(&(DateTime.compare(&1, end_dt) == :lt))
          |> Stream.reject(fn slot ->
              # Must be after minimum notice window
              DateTime.compare(slot, DateTime.add(now, notice * 60, :second)) == :lt
            end)
          |> Stream.reject(fn slot ->
              slot_end = DateTime.add(slot, dur * 60, :second)
              buf_secs = buf * 60
              # Check overlap with busy windows
              Enum.any?(busy, fn b ->
                s = b["start_at"]
                e = b["end_at"]
                s_dt = DateTime.from_unix!(s, :microsecond)
                e_dt = DateTime.from_unix!(e, :microsecond)
                DateTime.compare(slot, DateTime.add(e_dt, buf_secs, :second)) == :lt and
                DateTime.compare(DateTime.add(slot_end, buf_secs, :second), s_dt) == :gt
              end)
            end)
          |> Enum.map(fn slot ->
              %{
                start: slot,
                end:   DateTime.add(slot, dur * 60, :second),
              }
            end)
          |> Enum.take(100)

        {:ok, slots}
      end
    end
  end

  def book_slot(link_id, slot_start_str, booker_name, booker_email, answers) do
    with {:ok, link}     <- get_booking_link(link_id),
         {:ok, slot_start} <- parse_datetime(slot_start_str) do

      owner_did = link["did"]
      slot_end  = DateTime.add(slot_start, link["duration_mins"] * 60, :second)

      appointment = %{
        "title"         => "#{booker_name} — #{link["title"]}",
        "description"   => Enum.join(answers, "\n"),
        "category"      => "APPOINTMENT",
        "start_at"      => DateTime.to_unix(slot_start, :microsecond),
        "end_at"        => DateTime.to_unix(slot_end, :microsecond),
        "space"         => "core",
        "visibility"    => "private",
        "location_type" => link["location_type"] || "virtual",
        "location_ref"  => link["location_ref"] || "",
        "busy_status"   => "busy",
        "status"        => "confirmed",
        "attendees"     => [],
      }

      with {:ok, event} <- Events.create(owner_did, appointment) do
        # Notify owner via companion
        Endpoint.broadcast("calendar:personal:#{owner_did}", "booking:received", %{
          booking_link_id: link_id,
          slot_start:      DateTime.to_unix(slot_start, :microsecond),
          booker_name:     booker_name,
          booker_email:    booker_email,
        })

        # Send confirmation email to booker (Swoosh mailer)
        PRZMA.Mailer.send_booking_confirmation(%{
          to:         booker_email,
          name:       booker_name,
          event:      event,
          link:       link,
          answers:    answers,
        })

        {:ok, event}
      end
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────────

  defp verify_freebusy_access(target_did, requester_did) do
    cond do
      target_did == requester_did -> :ok
      in_shared_circle?(target_did, requester_did) -> :ok
      has_cross_did_grant?(target_did, requester_did) -> :ok
      true -> {:error, :access_denied}
    end
  end

  defp in_shared_circle?(target_did, requester_did) do
    target_circles    = PRZMA.Identity.list_circles_for_did(target_did) |> Enum.map(& &1.circle_did)
    requester_circles = PRZMA.Identity.list_circles_for_did(requester_did) |> Enum.map(& &1.circle_did)
    not Enum.empty?(target_circles -- (target_circles -- requester_circles))
  end

  defp has_cross_did_grant?(_target_did, _requester_did) do
    # Phase 3: check PostgreSQL cross_did_permissions table
    false
  end

  defp merge_overlapping(slots) do
    slots
    |> Enum.sort_by(& &1.start_at)
    |> Enum.reduce([], fn slot, acc ->
        case acc do
          [] -> [slot]
          [last | rest] ->
            if slot.start_at <= last.end_at do
              [Map.put(last, :end_at, max(last.end_at, slot.end_at)) | rest]
            else
              [slot | acc]
            end
        end
      end)
    |> Enum.reverse()
  end

  defp broadcast_availability_updated(did) do
    Endpoint.broadcast("calendar:personal:#{did}", "availability:updated", %{
      did: did,
      windows_changed: [],
    })
  end

  defp generate_id(did) do
    :crypto.hash(:sha256, "#{did}-avail-#{now_micros()}")
    |> Base.encode16(case: :lower)
  end

  defp generate_link_id do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end

  defp now_micros, do: System.os_time(:microsecond)

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> {:ok, dt}
      _            -> {:error, :invalid_datetime}
    end
  end
  defp parse_datetime(_), do: {:error, :invalid_datetime}
end
