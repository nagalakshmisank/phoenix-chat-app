# lib/session/agent_session.ex
#
# Agent session GenServer — one per active agent invocation.
#
# State machine:
#
#   :initialising → :running → :waiting_input → :running → :complete
#                     ↓                              ↓
#                   :paused  ←──────────────────  :paused
#                     ↓
#                   :cancelled
#
# The session stores its own pzdb:// URI in agents/{space}/sessions.lance.
# Every state transition is written to Lance so sessions survive node restarts.
# The AgentLoop runs as a supervised Task inside the session.
# Oban heartbeat job keeps the session alive and detects stalled loops.

defmodule PRZMA.Agents.Session do
  use GenServer
  require Logger

  alias PRZMA.Agents.{Loop, ExecutionLog}
  alias PRZMA.PzDb
  alias PRZMAWeb.Endpoint

  @heartbeat_interval_ms  10_000   # 10 seconds
  @idle_timeout_ms        300_000  # 5 minutes — session auto-closes if no activity
  @max_output_buffer       50      # broadcast immediately; keep last 50 outputs in state

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link({session_id, did, opts}) do
    GenServer.start_link(__MODULE__, {session_id, did, opts},
      name: via(session_id))
  end

  def send_message(session_id, message) do
    GenServer.call(via(session_id), {:message, message}, 30_000)
  end

  def get_state(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil -> {:error, :not_found}
      pid -> {:ok, GenServer.call(pid, :get_state)}
    end
  end

  def stop(session_id, reason \\ :user_requested) do
    GenServer.cast(via(session_id), {:stop, reason})
  end

  def pause(session_id) do
    GenServer.call(via(session_id), :pause)
  end

  def resume(session_id) do
    GenServer.call(via(session_id), :resume)
  end

  # Called by AgentLoop to deliver output chunks
  def output(session_id, chunk) do
    GenServer.cast(via(session_id), {:output, chunk})
  end

  # Called by AgentLoop when tool is invoked
  def tool_call(session_id, tool, input, result) do
    GenServer.cast(via(session_id), {:tool_call, tool, input, result})
  end

  # Called by AgentLoop when complete
  def complete(session_id, final_output) do
    GenServer.cast(via(session_id), {:complete, final_output})
  end

  # Called by AgentLoop on error
  def loop_error(session_id, reason) do
    GenServer.cast(via(session_id), {:loop_error, reason})
  end

  # ── GENSERVER ─────────────────────────────────────────────────────────────

  @impl true
  def init({session_id, did, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      session_id:   session_id,
      did:          did,
      agent_type:   opts.agent_type,
      space:        opts[:circle_did] && "circle:#{opts[:circle_did]}" || "core",
      context_uri:  opts[:context_uri],
      tool_grants:  opts.tool_grants,
      stream:       opts[:stream] || false,
      status:       :initialising,
      loop_pid:     nil,
      loop_task:    nil,
      messages:     [],      # conversation history
      output_buf:   [],      # recent outputs for late subscribers
      step_count:   0,
      started_at:   System.os_time(:microsecond),
      last_active:  System.os_time(:microsecond),
      error:        nil,
    }

    # Persist session to Lance
    persist_session(state)

    # Start the agent loop immediately
    {:ok, start_loop(state), @heartbeat_interval_ms}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, sanitise_state(state), state, @heartbeat_interval_ms}
  end

  def handle_call({:message, message}, _from, state) do
    new_msg = %{role: :user, content: message, ts: System.os_time(:microsecond)}
    state   = %{state |
      messages:    [new_msg | state.messages],
      last_active: System.os_time(:microsecond),
    }
    # Forward to loop if running, else queue
    if state.status == :running and state.loop_pid do
      send(state.loop_pid, {:user_message, message})
    end
    {:reply, :ok, %{state | status: :running}, @heartbeat_interval_ms}
  end

  def handle_call(:pause, _from, state) do
    if state.loop_pid, do: send(state.loop_pid, :pause)
    state = %{state | status: :paused}
    persist_session(state)
    broadcast(state, "agent:paused", %{session_id: state.session_id})
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, %{status: :paused} = state) do
    state = %{state | status: :running}
    if state.loop_pid, do: send(state.loop_pid, :resume)
    persist_session(state)
    broadcast(state, "agent:resumed", %{session_id: state.session_id})
    {:reply, :ok, state, @heartbeat_interval_ms}
  end
  def handle_call(:resume, _from, state), do: {:reply, {:error, :not_paused}, state}

  @impl true
  def handle_cast({:stop, reason}, state) do
    Logger.info("Agent session stopping",
      session_id: state.session_id, reason: reason)
    if state.loop_task, do: Task.shutdown(state.loop_task, :brutal_kill)
    state = %{state | status: :cancelled}
    persist_session(state)
    broadcast(state, "agent:stopped", %{reason: reason})
    {:stop, :normal, state}
  end

  def handle_cast({:output, chunk}, state) do
    # Broadcast to WebSocket channel
    broadcast(state, "agent:output", %{chunk: chunk, step: state.step_count})

    # Buffer last N outputs for late subscribers
    buf   = [chunk | state.output_buf] |> Enum.take(@max_output_buffer)
    state = %{state | output_buf: buf, last_active: System.os_time(:microsecond)}
    {:noreply, state, @heartbeat_interval_ms}
  end

  def handle_cast({:tool_call, tool, input, result}, state) do
    state = %{state | step_count: state.step_count + 1}

    # Log to Lance execution_log
    ExecutionLog.append(state.session_id, state.did, %{
      step:        state.step_count,
      tool:        tool,
      input_json:  Jason.encode!(input),
      output_json: Jason.encode!(result),
      status:      :ok,
      executed_at: System.os_time(:microsecond),
    })

    broadcast(state, "agent:tool_call", %{
      step:   state.step_count,
      tool:   tool,
      result: summarise_result(result),
    })

    {:noreply, state, @heartbeat_interval_ms}
  end

  def handle_cast({:complete, final_output}, state) do
    Logger.info("Agent session complete",
      session_id: state.session_id,
      steps: state.step_count,
      duration_ms: div(System.os_time(:microsecond) - state.started_at, 1_000))

    state = %{state | status: :complete}
    persist_session(state)
    broadcast(state, "agent:complete", %{
      output:   final_output,
      steps:    state.step_count,
      duration: div(System.os_time(:microsecond) - state.started_at, 1_000),
    })

    {:stop, :normal, state}
  end

  def handle_cast({:loop_error, reason}, state) do
    Logger.error("Agent loop error",
      session_id: state.session_id, reason: inspect(reason))
    state = %{state | status: :error, error: inspect(reason)}
    persist_session(state)
    broadcast(state, "agent:error", %{reason: inspect(reason)})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:timeout, %{status: :running} = state) do
    # Heartbeat — persist current state
    if div(System.os_time(:microsecond) - state.last_active, 1_000) > @idle_timeout_ms do
      Logger.info("Agent session idle timeout", session_id: state.session_id)
      {:stop, :normal, %{state | status: :timeout}}
    else
      persist_session(state)
      {:noreply, state, @heartbeat_interval_ms}
    end
  end
  def handle_info(:timeout, state), do: {:noreply, state, @heartbeat_interval_ms}

  def handle_info({:EXIT, pid, reason}, %{loop_pid: pid} = state) do
    unless reason in [:normal, :shutdown] do
      Logger.warning("Agent loop process died unexpectedly",
        session_id: state.session_id, reason: inspect(reason))
      # Restart the loop
      state = start_loop(state)
      {:noreply, state, @heartbeat_interval_ms}
    else
      {:noreply, state, @heartbeat_interval_ms}
    end
  end
  def handle_info({:EXIT, _, _}, state), do: {:noreply, state, @heartbeat_interval_ms}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task result — ignore, handled via cast
    Process.demonitor(ref, [:flush])
    {:noreply, state, @heartbeat_interval_ms}
  end

  @impl true
  def terminate(_reason, state) do
    persist_session(%{state | status: if(state.status == :running, do: :interrupted, else: state.status)})
    :ok
  end

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  defp start_loop(state) do
    task = Task.async(fn ->
      Loop.run(%{
        session_id:  state.session_id,
        did:         state.did,
        agent_type:  state.agent_type,
        context_uri: state.context_uri,
        tool_grants: state.tool_grants,
        messages:    state.messages,
        max_steps:   PRZMA.Agents.Registry.max_steps(
          PRZMA.Deployment.License.did_tier(state.did), state.agent_type),
      })
    end)

    broadcast(state, "agent:started", %{
      session_id: state.session_id,
      agent_type: state.agent_type,
    })

    %{state |
      loop_task: task,
      loop_pid:  task.pid,
      status:    :running,
    }
  end

  defp persist_session(state) do
    uri    = "pzdb://#{state.did}/agents/#{state.space}/sessions/#{state.session_id}"
    record = %{
      "id"               => state.session_id,
      "did"              => state.did,
      "agent_type"       => to_string(state.agent_type),
      "space"            => state.space,
      "status"           => to_string(state.status),
      "tool_grants_json" => Jason.encode!(Enum.map(state.tool_grants, & &1.tool)),
      "context_uri"      => state.context_uri,
      "heartbeat_at"     => System.os_time(:microsecond),
      "started_at"       => state.started_at,
      "output_uris_json" => "[]",
    }
    PzDb.write(uri, record, encrypt: false)
  end

  defp broadcast(state, event, payload) do
    Endpoint.broadcast("agent:session:#{state.session_id}", event, payload)
  end

  defp sanitise_state(state) do
    state
    |> Map.take([:session_id, :did, :agent_type, :status, :step_count,
                 :started_at, :last_active, :error, :output_buf])
  end

  defp summarise_result(result) when is_binary(result) and byte_size(result) > 200 do
    String.slice(result, 0, 200) <> "..."
  end
  defp summarise_result(result), do: result

  defp via(session_id) do
    {:via, Registry, {PRZMA.Agents.SessionRegistry, session_id}}
  end
end
