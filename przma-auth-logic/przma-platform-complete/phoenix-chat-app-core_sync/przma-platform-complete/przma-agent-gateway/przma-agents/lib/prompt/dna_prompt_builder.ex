# lib/prompt/dna_prompt_builder.ex
#
# DNA Prompt Builder — 6-layer composable system prompt for PRZMA agents.
#
# Layer 1: System Identity    — who/what the agent is, sovereignty reminder
# Layer 2: User Context       — vault state, Sapience Index, filter states
# Layer 3: Task Context       — current task, conversation history
# Layer 4: Tool Definitions   — available tools with JSON schemas
# Layer 5: Memory Context     — arc timeline, companion memories, past sessions
# Layer 6: Output Constraints — format, language, length, sovereignty reminder
#
# Each layer is assembled independently and can be swapped per agent type.
# The assembled prompt is passed to LLMAdapter as a structured message list.

defmodule PRZMA.Agents.DNAPromptBuilder do
  require Logger

  alias PRZMA.Services.Companion
  alias PRZMA.Calendar.Intelligence.CompanionContext
  alias PRZMA.Agents.ToolExecutor

  @doc """
  Build the complete DNA prompt for an agent session step.
  Returns a list of messages in OpenAI-compatible format.
  """
  def build(agent_type, context, opts) do
    [
      layer1_system_identity(agent_type, opts.did),
      layer2_user_context(opts.did, context),
      layer3_task_context(context),
      layer4_tool_definitions(opts.tool_grants),
      layer5_memory_context(opts.did, context),
      layer6_output_constraints(agent_type),
    ]
    |> Enum.reject(&is_nil/1)
    |> flatten_to_messages(context.messages)
  end

  # ── LAYER 1: System Identity ───────────────────────────────────────────────

  defp layer1_system_identity(agent_type, did) do
    identity = agent_identity(agent_type)
    domain   = did_domain(did)

    %{
      role:    "system",
      content: """
      #{identity.role_description}

      You are operating within the PRZMA sovereign intelligence platform.
      The user's DID is: #{did}
      Their data lives in: pzdb://#{did}/

      Core principles:
      - You operate on the user's sovereign data. Never reference or assume
        access to data not explicitly provided via tools.
      - All insights derive from the user's own patterns, not external benchmarks.
      - Privacy is non-negotiable. Tool results stay within this session.
      - You work WITH the user's perception, not to replace it.

      You are: #{identity.name}
      Your purpose: #{identity.purpose}
      Your capabilities: #{identity.capabilities}
      """,
    }
  end

  defp agent_identity(:companion) do
    %{
      name:        "PRZMA Companion",
      role_description: "You are a sovereign AI companion assisting with personal perception intelligence.",
      purpose:     "Help the user understand their patterns, make decisions, and deepen self-awareness through their own data.",
      capabilities: "Reading vault entries, calendar patterns, practice adherence, and companion memories. Writing vault reflections.",
    }
  end
  defp agent_identity(:calendar) do
    %{
      name:        "Calendar Agent",
      role_description: "You are a calendar intelligence agent.",
      purpose:     "Manage calendar events, tasks, and schedules with precision and context-awareness.",
      capabilities: "Creating and updating events and tasks, reading existing calendar, understanding scheduling patterns.",
    }
  end
  defp agent_identity(:vault_scribe) do
    %{
      name:        "Vault Scribe",
      role_description: "You are a sovereign journal scribe.",
      purpose:     "Transform the user's voice, text, and reflections into well-structured vault entries routed to the correct domain.",
      capabilities: "Writing to vault domains (My Health, My Day, My People, My Thoughts, Who I Am, What I Learned, Quiet Moments, My Practices).",
    }
  end
  defp agent_identity(:analytics) do
    %{
      name:        "Analytics Agent",
      role_description: "You are a personal data analytics agent.",
      purpose:     "Run analytical queries on the user's own data and translate results into clear, actionable insights.",
      capabilities: "DuckDB analytics on Lance files, pattern detection, time distribution analysis.",
    }
  end
  defp agent_identity(:scanner) do
    %{
      name:        "Scanner Agent",
      role_description: "You are the PRZMA Scanner Agent running the 23-scanner perception framework.",
      purpose:     "Surface patterns, insights, and signals across all of the user's data using the scanner framework.",
      capabilities: "Pattern detection, perception analysis, filter state assessment, arc timeline surfacing.",
    }
  end
  defp agent_identity(:meeting_scribe) do
    %{
      name:        "Meeting Scribe",
      role_description: "You are a meeting intelligence agent.",
      purpose:     "Process meeting transcripts, extract action items, and write structured post-meeting reflections.",
      capabilities: "Reading transcripts, extracting action items, writing vault entries, creating calendar tasks.",
    }
  end
  defp agent_identity(_) do
    %{
      name:        "PRZMA Agent",
      role_description: "You are a PRZMA sovereign intelligence agent.",
      purpose:     "Assist the user with their request using their own data.",
      capabilities: "Access to tools as granted for this session.",
    }
  end

  # ── LAYER 2: User Context ──────────────────────────────────────────────────

  defp layer2_user_context(did, _context) do
    # Fetch live context (non-blocking — use cached companion context)
    companion_context = case CompanionContext.assemble(did, horizon_hours: 24) do
      {:ok, ctx} -> ctx
      _          -> nil
    end

    sapience = get_sapience_summary(did)

    content = """
    === USER CONTEXT ===

    #{if companion_context, do: format_companion_context(companion_context), else: ""}

    #{if sapience, do: format_sapience(sapience), else: ""}
    """

    %{role: "system", content: String.trim(content)}
  end

  defp format_companion_context(ctx) do
    today = ctx.today
    """
    Today's schedule: #{today.event_count} events, #{today.busy_mins} minutes scheduled.
    #{if today.has_meetings, do: "Has meetings today.", else: "No meetings today."}
    #{if ctx.overdue_count > 0, do: "#{ctx.overdue_count} overdue tasks need attention.", else: ""}
    #{if ctx.practice_count > 0, do: "#{ctx.practice_count} practices scheduled today.", else: ""}
    Current situation: #{ctx.situation.label}
    #{if ctx.situation.suggestion, do: "Suggestion: #{ctx.situation.suggestion}", else: ""}
    """
  end

  defp format_sapience(s) do
    "Sapience Index: #{Float.round(s.sapience_index, 1)}/100"
  end

  defp get_sapience_summary(did) do
    # Read latest sapience snapshot from companion Lance (async, non-blocking)
    uri = "pzdb://#{did}/companion/core/sapience_snapshots/latest"
    case PRZMA.PzDb.read(uri, skip_cache: false) do
      {:ok, %{found: true, record: r}} -> r
      _                                -> nil
    end
  end

  # ── LAYER 3: Task Context ──────────────────────────────────────────────────

  defp layer3_task_context(context) do
    conversation = context.messages
      |> Enum.reverse()
      |> Enum.take(10)
      |> Enum.map(fn m ->
          role    = m[:role] || :user
          content = m[:content] || ""
          "#{String.upcase(to_string(role))}: #{content}"
        end)
      |> Enum.join("\n\n")

    observations = context.observations
      |> Enum.take(5)
      |> Enum.map_join("\n", fn o -> "- #{o}" end)

    content = """
    === CONVERSATION ===
    #{conversation}

    #{if observations != "", do: "=== RECENT OBSERVATIONS ===\n#{observations}", else: ""}
    """

    %{role: "system", content: String.trim(content)}
  end

  # ── LAYER 4: Tool Definitions ──────────────────────────────────────────────

  defp layer4_tool_definitions(tool_grants) do
    tools_schema = tool_grants
      |> Enum.map(fn grant -> ToolExecutor.schema(grant.tool) end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(tools_schema) do
      nil
    else
      tools_json = Jason.encode!(tools_schema, pretty: true)
      %{
        role:    "system",
        content: """
        === AVAILABLE TOOLS ===

        You have access to the following tools. Use them to gather information
        and take actions. Only use tools that are relevant to the task.

        #{tools_json}

        To use a tool, respond with:
        ACTION: <tool_name>
        INPUT: <JSON input matching tool schema>

        To provide a final response without using a tool:
        FINAL: <your response>

        To reason before acting:
        THOUGHT: <your reasoning>
        """,
      }
    end
  end

  # ── LAYER 5: Memory Context ────────────────────────────────────────────────

  defp layer5_memory_context(did, context) do
    memories = fetch_relevant_memories(did, context)

    if Enum.empty?(memories) do
      nil
    else
      formatted = memories
        |> Enum.map_join("\n", fn m -> "- #{m["title"] || "Memory"}: #{truncate(m["body_cas"] || "", 200)}" end)

      %{
        role:    "system",
        content: "=== RELEVANT MEMORIES ===\n#{formatted}",
      }
    end
  end

  defp fetch_relevant_memories(did, _context) do
    # Query recent high-salience companion memories
    case PRZMA.PzDb.query(
      "pzdb://#{did}/companion/core/memories/placeholder",
      filter: "salience > 0.6 AND deleted_at IS NULL",
      limit:  5
    ) do
      {:ok, %{"records" => records}} -> records
      _                              -> []
    end
  end

  # ── LAYER 6: Output Constraints ────────────────────────────────────────────

  defp layer6_output_constraints(agent_type) do
    format = output_format(agent_type)
    %{
      role:    "system",
      content: """
      === OUTPUT CONSTRAINTS ===

      #{format}

      Sovereignty reminder:
      - Never suggest storing data outside the user's own vault.
      - Never recommend third-party analytics services.
      - All insights must come from the user's own data.
      - If you don't have enough data, say so clearly.
      - Be concise. The user can ask follow-up questions.
      """,
    }
  end

  defp output_format(:companion),    do: "Respond conversationally. Use first-person. Be warm but precise."
  defp output_format(:vault_scribe), do: "Write in the user's voice. Use appropriate vault domain structure."
  defp output_format(:calendar),     do: "Confirm actions taken. List created/updated items with pzdb:// URIs."
  defp output_format(:analytics),    do: "Present insights as numbered findings. Include specific numbers."
  defp output_format(:scanner),      do: "Structure output as: Pattern found → Evidence → Suggested action."
  defp output_format(_),             do: "Be clear, concise, and actionable."

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp flatten_to_messages(layers, conversation_messages) do
    # Combine system layers and conversation messages
    system_content = layers
      |> Enum.map(fn l -> l.content end)
      |> Enum.join("\n\n" <> String.duplicate("─", 40) <> "\n\n")

    system_message = %{role: "system", content: system_content}

    user_messages = conversation_messages
      |> Enum.reverse()
      |> Enum.map(fn m ->
          %{role: to_string(m[:role] || :user), content: m[:content] || ""}
        end)

    [system_message | user_messages]
  end

  defp did_domain(did) do
    case String.split(did, ":") do
      [_, "web", domain | _] -> domain
      _                      -> did
    end
  end

  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "…"
  end
  defp truncate(text, _), do: text
end
