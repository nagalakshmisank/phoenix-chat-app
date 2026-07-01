# lib/przma/calendar/intelligence/pre_brief.ex
#
# Assembles pre-meeting context from the user's sovereign vault.
# Surfaces: past interactions with attendees, open tasks, meeting load,
# and suggested agenda. Runs fully local — no PRZMA server involvement.

defmodule PRZMA.Calendar.Intelligence.PreBrief do
  alias PRZMA.Calendar.NIF
  alias PRZMAWeb.Endpoint
  require Logger

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── PUBLIC API ───────────────────────────────────────────────────────────

  @doc """
  Assemble a pre-brief for a calendar event.
  Returns structured context including attendee history, open actions,
  meeting load, and agenda suggestions.
  """
  def assemble(did, event_id, space \\ "core") do
    with {:ok, event} <- PRZMA.Calendar.Events.get(did, event_id, space) do
      case NIF.assemble_pre_brief(@base_path, did, Jason.encode!(event)) do
        {:ok, json}   ->
          brief = Jason.decode!(json)
          # Enrich with companion memory summary (Phase 6: Arc Engine)
          enriched = enrich_with_companion_context(brief, did, event)
          {:ok, enriched}

        {:error, msg} ->
          Logger.warning("Pre-brief assembly failed", event_id: event_id, error: msg)
          {:ok, fallback_brief(event)}
      end
    end
  end

  @doc """
  Deliver pre-brief to the user's companion channel.
  Called automatically 10 minutes before a MEETING event starts.
  """
  def deliver_to_companion(did, event_id) do
    with {:ok, brief} <- assemble(did, event_id) do
      Endpoint.broadcast("calendar:personal:#{did}", "companion:pre_brief", %{
        type:     "pre_meeting_brief",
        event_id: event_id,
        brief:    brief,
        prompt:   build_companion_prompt(brief),
      })
      {:ok, brief}
    end
  end

  # ── PRIVATE ──────────────────────────────────────────────────────────────

  defp enrich_with_companion_context(brief, did, event) do
    # Phase 6: query Arc Engine for longitudinal patterns
    # For Phase 4: add companion memory summary placeholder
    Map.put(brief, "companion_context", %{
      memory_summary:  "Context from previous sessions with these attendees",
      pattern_insights: [],
      suggested_focus: build_focus_suggestion(brief),
    })
  end

  defp build_companion_prompt(brief) do
    attendee_count = length(brief["attendee_context"] || [])
    action_count   = length(brief["open_action_items"] || [])
    load           = brief["meeting_load"] || %{}

    parts = []
    parts = if attendee_count > 0 do
      names = brief["attendee_context"]
        |> Enum.map(fn c -> short_name(c["did"]) end)
        |> Enum.join(", ")
      ["Meeting with #{names}." | parts]
    else
      parts
    end

    parts = if action_count > 0 do
      ["You have #{action_count} open action item(s) from previous meetings." | parts]
    else
      parts
    end

    parts = if load["back_to_back"] do
      ["This is a back-to-back meeting — you may want a moment to prepare." | parts]
    else
      parts
    end

    parts = if (brief["suggested_agenda"] || []) != [] do
      agenda_str = brief["suggested_agenda"] |> Enum.take(3) |> Enum.join(" · ")
      ["Suggested topics: #{agenda_str}" | parts]
    else
      parts
    end

    parts |> Enum.reverse() |> Enum.join(" ")
  end

  defp build_focus_suggestion(brief) do
    cond do
      has_overdue_actions?(brief) -> "Follow up on overdue action items"
      high_meeting_load?(brief)   -> "Keep this meeting focused — you have a heavy schedule today"
      true                        -> "Check in on open tasks and discuss next steps"
    end
  end

  defp has_overdue_actions?(brief) do
    now = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
    (brief["open_action_items"] || [])
    |> Enum.any?(fn a -> a["due_at"] && a["due_at"] < now end)
  end

  defp high_meeting_load?(brief) do
    load = brief["meeting_load"] || %{}
    (load["meetings_today"] || 0) >= 4 or (load["total_meeting_mins"] || 0) >= 240
  end

  defp fallback_brief(event) do
    %{
      "event_id"          => event["id"],
      "assembled_at"      => DateTime.utc_now() |> DateTime.to_iso8601(),
      "attendee_context"  => [],
      "relevant_items"    => [],
      "open_action_items" => [],
      "suggested_agenda"  => ["Discuss agenda and priorities"],
      "meeting_load"      => %{},
    }
  end

  defp short_name(did) do
    did |> String.split(":") |> List.last() |> String.capitalize()
  end
end
