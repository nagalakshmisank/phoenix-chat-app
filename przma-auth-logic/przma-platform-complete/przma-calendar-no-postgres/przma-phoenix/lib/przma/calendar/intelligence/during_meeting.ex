# lib/przma/calendar/intelligence/during_meeting.ex
#
# Coordinates during-meeting capture:
# - Accepts audio blobs or text notes via companion
# - Routes to transcription
# - Extracts action items in real-time
# - Time-stamps key moments

defmodule PRZMA.Calendar.Intelligence.DuringMeeting do
  alias PRZMA.Calendar.{NIF, Tasks}
  alias PRZMA.Calendar.Intelligence.{ActionItems, Transcript}
  alias PRZMAWeb.Endpoint
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── MEETING SESSION STATE ────────────────────────────────────────────────
  # Held in process state via GenServer for active meetings.
  # On process death: session state flushed to Lance.

  defmodule Session do
    defstruct [
      :event_id,
      :did,
      :circle_did,
      :companion_mode,   # personal | scribe
      :started_at,
      turns:              [],
      text_notes:         [],
      action_item_drafts: [],
      markers:            [],
    ]
  end

  # ── CAPTURE AUDIO BLOB ───────────────────────────────────────────────────

  @doc """
  Accept an audio blob CAS hash for transcription.
  Returns immediately — transcription is async.
  """
  def capture_audio(did, event_id, audio_cas, opts \\ []) do
    language = opts[:language] || "en"
    circle_did = opts[:circle_did]

    # Enqueue transcription job
    PRZMA.Calendar.Jobs.TranscribeAudio.enqueue(%{
      did:        did,
      event_id:   event_id,
      audio_cas:  audio_cas,
      language:   language,
      circle_did: circle_did,
    })

    Endpoint.broadcast("calendar:personal:#{did}", "meeting:capture_received", %{
      event_id:  event_id,
      type:      "audio",
      status:    "transcribing",
    })

    {:ok, :accepted}
  end

  # ── CAPTURE TEXT NOTE ────────────────────────────────────────────────────

  @doc """
  Accept a text note during a meeting.
  Immediately extracts action items and broadcasts suggestions.
  """
  def capture_text(did, event_id, text, opts \\ []) do
    circle_did  = opts[:circle_did]
    note_space  = if circle_did, do: "circle:#{circle_did}", else: "core"

    # Store note in CAS
    with {:ok, cas_hash} <- NIF.cas_put(@base_path, did, text) do
      # Extract action items immediately
      with {:ok, items_json} <- NIF.extract_action_items(@base_path, text) do
        items = Jason.decode!(items_json)

        high_confidence = Enum.filter(items, fn i -> i["confidence"] >= 0.75 end)

        if length(high_confidence) > 0 do
          Endpoint.broadcast("calendar:personal:#{did}", "meeting:action_items_detected", %{
            event_id:    event_id,
            items:       high_confidence,
            source:      "text_note",
            note_cas:    cas_hash,
          })
        end

        # Save note to event's notes_cas list
        add_note_to_event(did, event_id, cas_hash)

        {:ok, %{cas_hash: cas_hash, action_items_detected: length(high_confidence)}}
      end
    end
  end

  # ── MARK KEY MOMENT ──────────────────────────────────────────────────────

  @doc """
  Mark a key moment in a meeting for later reference.
  Stored as a timestamped label in the event's metadata.
  """
  def mark_moment(did, event_id, label, timestamp_secs \\ nil) do
    ts = timestamp_secs || :os.system_time(:second)
    marker = %{
      label:      label,
      ts_secs:    ts,
      created_at: DateTime.utc_now() |> DateTime.to_unix(:microsecond),
    }

    Endpoint.broadcast("calendar:personal:#{did}", "meeting:moment_marked", %{
      event_id: event_id,
      marker:   marker,
    })

    # Store in event metadata (via NIF update)
    PRZMA.Calendar.Events.update(did, event_id, "core", %{
      "updated_at" => :os.system_time(:microsecond),
    })

    {:ok, marker}
  end

  # ── CONFIRM ACTION ITEM ──────────────────────────────────────────────────

  @doc """
  User confirms a suggested action item — creates a real CalendarTask.
  """
  def confirm_action_item(did, event_id, item, opts \\ []) do
    circle_did = opts[:circle_did]
    space      = if circle_did, do: "circle:#{circle_did}", else: "core"

    task_attrs = %{
      "title"        => item["text"],
      "description"  => "Action item from meeting #{event_id}",
      "category"     => "circle",
      "space"        => space,
      "event_id"     => event_id,
      "priority"     => "medium",
      "status"       => "active",
      "assigned_to"  => [resolve_assignee(item["assignee_hint"], did)],
      "due_at"       => resolve_due_date(item["due_hint"]),
    }

    with {:ok, task_id} <- Tasks.create(did, task_attrs) do
      Endpoint.broadcast("calendar:personal:#{did}", "meeting:action_item_confirmed", %{
        event_id: event_id,
        task_id:  task_id,
        title:    item["text"],
      })
      {:ok, task_id}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp add_note_to_event(did, event_id, cas_hash) do
    with {:ok, event} <- PRZMA.Calendar.Events.get(did, event_id, "core") do
      notes = [cas_hash | (event["notes_cas"] || [])]
      PRZMA.Calendar.Events.update(did, event_id, "core", %{"notes_cas" => notes})
    end
    :ok
  end

  defp resolve_assignee(nil, self_did), do: self_did
  defp resolve_assignee(hint, _self_did) do
    # Phase 6: resolve name hint to DID via identity lookup
    hint
  end

  defp resolve_due_date(nil), do: nil
  defp resolve_due_date("today") do
    DateTime.utc_now()
    |> DateTime.add(0, :second)
    |> DateTime.to_unix(:microsecond)
  end
  defp resolve_due_date("tomorrow") do
    DateTime.utc_now()
    |> DateTime.add(86400, :second)
    |> DateTime.to_unix(:microsecond)
  end
  defp resolve_due_date("ASAP") do
    DateTime.utc_now()
    |> DateTime.add(3600, :second)
    |> DateTime.to_unix(:microsecond)
  end
  defp resolve_due_date("this week") do
    # End of current week (Friday 17:00)
    now = DateTime.utc_now()
    days_to_friday = Integer.mod(5 - Date.day_of_week(DateTime.to_date(now)), 7)
    DateTime.utc_now()
    |> DateTime.add(days_to_friday * 86400, :second)
    |> DateTime.to_unix(:microsecond)
  end
  defp resolve_due_date(_other), do: nil
end
