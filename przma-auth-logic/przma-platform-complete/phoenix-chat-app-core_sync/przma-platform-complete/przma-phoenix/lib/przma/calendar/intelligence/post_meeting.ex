# lib/przma/calendar/intelligence/post_meeting.ex
#
# Post-meeting reflection pipeline:
# - Triggered automatically when event end_at passes
# - Prompts vault reflection via companion
# - Extracts and confirms action items from transcript
# - Optionally routes summary to circle

defmodule PRZMA.Calendar.Intelligence.PostMeeting do
  alias PRZMA.Calendar.{NIF, Events, Tasks, Circles}
  alias PRZMAWeb.Endpoint
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── REFLECTION TRIGGER ──────────────────────────────────────────────────

  @doc """
  Trigger post-meeting reflection flow for a completed event.
  Called by Oban job 5 minutes after event end_at.
  """
  def trigger(did, event_id, opts \\ []) do
    with {:ok, event} <- Events.get(did, event_id, opts[:space] || "core") do
      # Assemble post-meeting context
      context = build_post_context(did, event)

      # Send reflection prompt to companion channel
      Endpoint.broadcast("calendar:personal:#{did}", "companion:prompt", %{
        type:                "post_meeting_reflection",
        event_id:            event_id,
        prompt:              reflection_prompt(event, context),
        context:             context,
        target_vault_domain: vault_domain(event),
        suggested_tasks:     context.suggested_tasks,
        auto_dismiss_secs:   300,  # dismiss if no response in 5 minutes
      })

      Logger.info("Post-meeting reflection triggered",
        event_id: event_id, did: did)
      {:ok, :triggered}
    end
  end

  # ── REFLECTION SUBMISSION ────────────────────────────────────────────────

  @doc """
  Process a submitted post-meeting reflection.
  Stores vault entry, confirms action items, routes summary to circle.
  """
  def submit_reflection(did, event_id, %{
    "reflection_text" => text,
    "confirmed_tasks" => confirmed_tasks,
    "share_summary"   => share_summary,
    "circle_did"      => circle_did,
  } = params) do
    with {:ok, event} <- Events.get(did, event_id, params["space"] || "core") do
      # 1. Store reflection in CAS and link to event
      {:ok, reflection_cas} = NIF.store_transcript_text(@base_path, did, text)
      add_reflection_to_event(did, event, reflection_cas)

      # 2. Confirm selected action items as real tasks
      task_ids = create_confirmed_tasks(did, event_id, confirmed_tasks, circle_did)

      # 3. Optionally share summary to circle
      if share_summary && circle_did do
        share_summary_to_circle(did, circle_did, event, text, task_ids)
      end

      # 4. Mark event as having a reflection
      Events.update(did, event_id, event["space"], %{"has_reflection" => true})

      Logger.info("Post-meeting reflection submitted",
        event_id: event_id, tasks_created: length(task_ids))

      {:ok, %{
        reflection_cas: reflection_cas,
        task_ids:       task_ids,
        shared:         share_summary && !is_nil(circle_did),
      }}
    end
  end

  # ── TRANSCRIPT PROCESSING ────────────────────────────────────────────────

  @doc """
  Process a completed transcript for a meeting.
  Extracts action items and sends suggestions to companion.
  Called by TranscribeAudio job after TFLite completes.
  """
  def process_transcript(did, event_id, transcript_json) do
    transcript = Jason.decode!(transcript_json)

    # Extract action items from transcript
    with {:ok, items_json} <- NIF.extract_action_items_from_turns(
           @base_path,
           Jason.encode!(transcript["turns"] || [])) do

      items    = Jason.decode!(items_json)
      deduped  = deduplicate_with_existing(items, event_id, did)
      filtered = Enum.filter(deduped, fn i -> i["confidence"] >= 0.65 end)

      # Store transcript
      NIF.save_transcript(@base_path, did, Jason.encode!(
        Map.put(transcript, "action_items", filtered)
      ))

      # Broadcast action item suggestions
      if length(filtered) > 0 do
        Endpoint.broadcast("calendar:personal:#{did}", "meeting:transcript_processed", %{
          event_id:       event_id,
          action_items:   filtered,
          word_count:     transcript["word_count"] || 0,
          duration_secs:  transcript["duration_secs"] || 0,
          speaker_count:  transcript["speaker_count"] || 1,
        })
      end

      {:ok, %{action_items: filtered, transcript_id: transcript["id"]}}
    end
  end

  # ── MEETING SUMMARY BUILDER ──────────────────────────────────────────────

  @doc """
  Build a structured meeting summary for circle sharing.
  Includes: key decisions, action items, next steps.
  Companion-redacted version for circle publishing.
  """
  def build_summary(did, event_id) do
    with {:ok, event}      <- Events.get(did, event_id, "core"),
         {:ok, transcript} <- get_or_nil_transcript(did, event_id),
         {:ok, tasks}      <- get_meeting_tasks(did, event_id) do

      # Get transcript text if available
      transcript_text = case transcript do
        nil -> nil
        t   ->
          case NIF.get_transcript_text(@base_path, did, t["text_cas"]) do
            {:ok, text} -> text
            _           -> nil
          end
      end

      {:ok, %{
        event_id:       event_id,
        title:          event["title"],
        date:           event["start_at"],
        duration_secs:  (event["end_at"] - event["start_at"]) / 1_000_000,
        attendees:      event["attendees"] || [],
        action_items:   Enum.map(tasks, fn t ->
          %{title: t["title"], assigned_to: t["assigned_to"], due_at: t["due_at"]}
        end),
        has_transcript: transcript != nil,
        transcript_preview: preview_text(transcript_text, 500),
        generated_at:   DateTime.utc_now() |> DateTime.to_unix(:microsecond),
      }}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp build_post_context(did, event) do
    # Gather tasks created during/for this meeting
    {:ok, tasks} = get_meeting_tasks(did, event["id"])

    # Check if transcript exists
    has_transcript = case NIF.get_transcript_for_event(@base_path, did, event["id"]) do
      {:ok, _}         -> true
      {:error, "not_found"} -> false
      _               -> false
    end

    %{
      has_transcript:  has_transcript,
      suggested_tasks: Enum.map(tasks, fn t ->
        %{title: t["title"], id: t["id"]}
      end),
      attendee_count:  length(event["attendees"] || []),
      duration_mins:   div((event["end_at"] - event["start_at"]), 60_000_000),
    }
  end

  defp reflection_prompt(event, context) do
    base = "How did your #{event["category"] |> String.downcase()} go?"

    followups = [
      if context.has_transcript do
        "I've processed the transcript and found #{length(context.suggested_tasks)} possible action items. Would you like to review them?"
      end,
      if context.attendee_count > 0 do
        "Any key insights or follow-ups from the conversation?"
      end,
    ] |> Enum.filter(& &1) |> Enum.join(" ")

    if followups != "", do: "#{base} #{followups}", else: base
  end

  defp vault_domain(event) do
    case event["category"] do
      "MEETING"     -> "My People"
      "PRACTICE"    -> "My Practices"
      "STUDY"       -> "What I Learned"
      "APPOINTMENT" -> "My Health"
      _             -> "My Day"
    end
  end

  defp create_confirmed_tasks(did, event_id, confirmed_tasks, circle_did) do
    space = if circle_did, do: "circle:#{circle_did}", else: "core"
    confirmed_tasks
    |> Enum.map(fn item ->
      attrs = %{
        "title"       => item["text"],
        "space"       => space,
        "circle_did"  => circle_did,
        "event_id"    => event_id,
        "status"      => "active",
        "priority"    => "medium",
        "assigned_to" => [item["assignee_hint"] || did],
        "due_at"      => item["due_at"],
      }
      case Tasks.create(did, attrs) do
        {:ok, id} -> id
        _         -> nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp share_summary_to_circle(did, circle_did, event, reflection_text, task_ids) do
    summary_note = %{
      "type"      => "meeting_summary",
      "event_id"  => event["id"],
      "title"     => "Summary: #{event["title"]}",
      "text"      => truncate(reflection_text, 500),
      "task_ids"  => task_ids,
      "created_at" => DateTime.utc_now() |> DateTime.to_unix(:microsecond),
    }
    # Route to circle chat namespace (Phase 5: full note routing)
    Endpoint.broadcast("calendar:circle:#{circle_did}:#{did}", "meeting:summary_shared", %{
      event_id: event["id"],
      summary:  summary_note,
    })
  end

  defp add_reflection_to_event(did, event, reflection_cas) do
    with {:ok, current} <- Events.get(did, event["id"], event["space"]) do
      notes = [reflection_cas | (current["notes_cas"] || [])]
      Events.update(did, event["id"], event["space"], %{"notes_cas" => notes})
    end
  end

  defp get_meeting_tasks(did, event_id) do
    {:ok, tasks} = PRZMA.Calendar.Tasks.list(did, space: "core", status: "active")
    meeting_tasks = Enum.filter(tasks, fn t -> t["event_id"] == event_id end)
    {:ok, meeting_tasks}
  end

  defp get_or_nil_transcript(did, event_id) do
    case NIF.get_transcript_for_event(@base_path, did, event_id) do
      {:ok, json}          -> {:ok, Jason.decode!(json)}
      {:error, "not_found"} -> {:ok, nil}
      error                -> error
    end
  end

  defp deduplicate_with_existing(new_items, event_id, did) do
    # Phase 6: check against existing tasks for event_id to avoid duplicates
    new_items
  end

  defp preview_text(nil, _), do: nil
  defp preview_text(text, max_chars) when byte_size(text) <= max_chars, do: text
  defp preview_text(text, max_chars), do: String.slice(text, 0, max_chars) <> "…"

  defp truncate(text, max_chars) do
    if String.length(text) <= max_chars do
      text
    else
      String.slice(text, 0, max_chars) <> "…"
    end
  end
end
