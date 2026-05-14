# lib/gateway/agent_gateway.ex
#
# PRZMA Agent Services Gateway
#
# Single entry point for all agentic services across the platform.
# Every agent request passes through:
#
#   Client → AgentGateway → AgentRateLimiter → ToolGrantManager
#          → AgentRegistry (type check) → AgentSupervisor
#          → AgentSession (GenServer) → AgentLoop (Task)
#          → ToolExecutor → PRZMA Services (calendar, vault, chat...)
#
# Agent tiers (from platform license):
#   free_local   — companion only,      10 sessions/hour,   5 tool calls/session
#   essential    — +1 custom agent,     50 sessions/hour,   20 tool calls/session
#   professional — +5 custom agents,   200 sessions/hour,   50 tool calls/session
#   sovereign    — unlimited agents,  1000 sessions/hour,  unlimited tool calls

defmodule PRZMA.Agents.Gateway do
  require Logger

  alias PRZMA.Agents.{
    Registry,
    Supervisor,
    Session,
    RateLimiter,
    ToolGrantManager,
  }

  # ── PUBLIC API ──────────────────────────────────────────────────────────────

  @doc """
  Start a new agent session.

  opts:
    agent_type:    atom — :companion | :calendar | :vault_scribe | :file_organizer |
                          :metadata_indexer | :analytics | :scanner | :custom
    context_uri:  pzdb:// URI of the primary resource this agent works on
    tool_grants:  list of tools to grant — validated against tier
    circle_did:   optional — for circle-scoped agents
    input:        initial task / message for the agent
    stream:       boolean — whether to stream output via channel
  """
  def start_session(did, opts) do
    agent_type  = Keyword.fetch!(opts, :agent_type)
    context_uri = opts[:context_uri]
    input       = opts[:input] || ""

    with :ok <- RateLimiter.check_session_limit(did),
         :ok <- Registry.check_agent_available(did, agent_type),
         {:ok, granted_tools} <- ToolGrantManager.issue_grants(did, agent_type, opts[:tool_grants] || []),
         {:ok, session_id}    <- Supervisor.start_session(did, %{
           agent_type:   agent_type,
           context_uri:  context_uri,
           tool_grants:  granted_tools,
           circle_did:   opts[:circle_did],
           stream:       opts[:stream] || false,
         }) do

      # Emit initial input if provided
      if input != "" do
        Session.send_message(session_id, input)
      end

      {:ok, %{
        session_id: session_id,
        agent_type: agent_type,
        status:     :starting,
        tool_grants: Enum.map(granted_tools, & &1.tool),
      }}
    end
  end

  @doc "Send a message to an active agent session."
  def send_message(did, session_id, message) do
    with :ok <- verify_session_owner(did, session_id),
         :ok <- RateLimiter.check_message_limit(did) do
      Session.send_message(session_id, message)
    end
  end

  @doc "Get the current state of a session."
  def get_session(did, session_id) do
    with :ok <- verify_session_owner(did, session_id) do
      Session.get_state(session_id)
    end
  end

  @doc "List all active sessions for a DID."
  def list_sessions(did) do
    Supervisor.sessions_for(did)
  end

  @doc "Stop an agent session gracefully."
  def stop_session(did, session_id) do
    with :ok <- verify_session_owner(did, session_id) do
      Session.stop(session_id, :user_requested)
    end
  end

  @doc "Pause an agent session (preserves state)."
  def pause_session(did, session_id) do
    with :ok <- verify_session_owner(did, session_id) do
      Session.pause(session_id)
    end
  end

  @doc "Resume a paused session."
  def resume_session(did, session_id) do
    with :ok <- verify_session_owner(did, session_id) do
      Session.resume(session_id)
    end
  end

  @doc "Get execution log for a session."
  def execution_log(did, session_id, opts \\ []) do
    with :ok <- verify_session_owner(did, session_id) do
      PRZMA.Agents.ExecutionLog.list(session_id, opts)
    end
  end

  # ── PRIVATE ─────────────────────────────────────────────────────────────────

  defp verify_session_owner(did, session_id) do
    case Session.get_state(session_id) do
      {:ok, %{did: ^did}}   -> :ok
      {:ok, %{did: _other}} -> {:error, :not_your_session}
      {:error, :not_found}  -> {:error, :session_not_found}
    end
  end
end
