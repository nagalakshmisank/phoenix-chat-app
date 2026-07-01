# lib/loop/agent_loop.ex
#
# Agent execution loop — ReAct pattern (Reasoning + Acting).
#
# Each step:
#   1. THINK  — build DNA prompt with current context + history
#   2. ACT    — call LLM, parse tool selection
#   3. EXECUTE — run tool through ToolExecutor (grant-checked)
#   4. OBSERVE — add result to context, broadcast to session
#   5. DECIDE  — continue? final response? max steps reached?
#
# The loop runs as a supervised Task inside AgentSession.
# It communicates with the session via Session.output/2 and Session.tool_call/4.
# The loop is pauseable: it checks for :pause messages between steps.

defmodule PRZMA.Agents.Loop do
  require Logger

  alias PRZMA.Agents.{Session, DNAPromptBuilder, ToolExecutor, LLMAdapter}

  @type loop_opts :: %{
    session_id:  String.t(),
    did:         String.t(),
    agent_type:  atom(),
    context_uri: String.t() | nil,
    tool_grants: list(),
    messages:    list(),
    max_steps:   integer(),
  }

  # ── MAIN LOOP ─────────────────────────────────────────────────────────────

  @doc "Entry point — called by Task.async inside AgentSession."
  def run(%{session_id: sid} = opts) do
    Logger.metadata(session_id: sid, agent_type: opts.agent_type)
    Logger.info("Agent loop starting", max_steps: opts.max_steps)

    context = build_initial_context(opts)

    result = run_steps(opts, context, 0)

    case result do
      {:ok, final_output} ->
        Session.complete(sid, final_output)
      {:error, reason} ->
        Session.loop_error(sid, reason)
    end
  end

  # ── STEP EXECUTION ────────────────────────────────────────────────────────

  defp run_steps(opts, context, step) when step >= opts.max_steps do
    Logger.info("Agent reached max steps", steps: step)
    final = "I've completed #{step} steps. Here is what I found:\n\n" <>
            (context.observations |> Enum.reverse() |> Enum.take(3) |> Enum.join("\n\n"))
    {:ok, final}
  end

  defp run_steps(opts, context, step) do
    # Check for pause message before each step
    receive do
      :pause ->
        Logger.info("Agent loop paused at step #{step}")
        wait_for_resume(opts, context, step)
      {:user_message, msg} ->
        # Inject user message into context
        new_context = add_user_message(context, msg)
        run_steps(opts, new_context, step)
    after
      0 -> :no_message
    end

    # ── THINK: Build prompt ─────────────────────────────────────────────────
    prompt = DNAPromptBuilder.build(opts.agent_type, context, opts)

    # ── ACT: Call LLM ──────────────────────────────────────────────────────
    case LLMAdapter.call(prompt, opts.tool_grants) do
      {:ok, %{type: :tool_call, tool: tool, input: input}} ->
        Logger.debug("Agent tool call", step: step, tool: tool)
        Session.output(opts.session_id, "[#{step+1}] Using tool: #{tool}")

        # ── EXECUTE: Run tool ───────────────────────────────────────────────
        case ToolExecutor.execute(opts.did, tool, input, opts.tool_grants) do
          {:ok, result} ->
            Session.tool_call(opts.session_id, tool, input, result)

            observation = format_observation(tool, result)
            context     = add_observation(context, step, tool, input, observation)

            run_steps(opts, context, step + 1)

          {:error, :tool_not_granted} ->
            Session.output(opts.session_id, "[#{step+1}] Tool #{tool} is not authorised for this session.")
            context = add_error_observation(context, step, "Tool not granted: #{tool}")
            run_steps(opts, context, step + 1)

          {:error, reason} ->
            observation = "Tool #{tool} failed: #{inspect(reason)}"
            context     = add_error_observation(context, step, observation)
            Session.output(opts.session_id, "[#{step+1}] #{observation}")
            run_steps(opts, context, step + 1)
        end

      {:ok, %{type: :final_response, content: output}} ->
        # LLM decided it has enough information
        Logger.info("Agent completed with final response", steps: step)
        Session.output(opts.session_id, output)
        {:ok, output}

      {:ok, %{type: :thinking, content: thought}} ->
        # LLM is reasoning — show thought, continue
        Session.output(opts.session_id, "Thinking: #{thought}")
        context = add_thought(context, thought)
        run_steps(opts, context, step + 1)

      {:error, reason} ->
        Logger.error("LLM call failed", reason: inspect(reason))
        {:error, {:llm_error, reason}}
    end
  end

  # ── PAUSE / RESUME ────────────────────────────────────────────────────────

  defp wait_for_resume(opts, context, step) do
    receive do
      :resume ->
        Logger.info("Agent loop resumed at step #{step}")
        run_steps(opts, context, step)
      {:user_message, msg} ->
        Logger.info("Received message while paused — resuming")
        new_context = add_user_message(context, msg)
        run_steps(opts, new_context, step)
      {:stop, reason} ->
        {:error, {:stopped, reason}}
    end
  end

  # ── CONTEXT MANAGEMENT ────────────────────────────────────────────────────

  defp build_initial_context(opts) do
    %{
      agent_type:   opts.agent_type,
      did:          opts.did,
      context_uri:  opts.context_uri,
      messages:     opts.messages,
      observations: [],
      thoughts:     [],
      step_history: [],
    }
  end

  defp add_observation(ctx, step, tool, input, observation) do
    entry = %{step: step, tool: tool, input: input, observation: observation}
    %{ctx |
      observations: [observation | ctx.observations],
      step_history: [entry    | ctx.step_history],
    }
  end

  defp add_error_observation(ctx, step, error_msg) do
    %{ctx | observations: [error_msg | ctx.observations],
            step_history: [%{step: step, error: error_msg} | ctx.step_history]}
  end

  defp add_thought(ctx, thought) do
    %{ctx | thoughts: [thought | ctx.thoughts]}
  end

  defp add_user_message(ctx, message) do
    msg = %{role: :user, content: message, ts: System.os_time(:microsecond)}
    %{ctx | messages: [msg | ctx.messages]}
  end

  defp format_observation(tool, result) when is_map(result) do
    Jason.encode!(result, pretty: true)
  end
  defp format_observation(tool, result) when is_binary(result) do
    result
  end
  defp format_observation(tool, result) do
    inspect(result)
  end
end
