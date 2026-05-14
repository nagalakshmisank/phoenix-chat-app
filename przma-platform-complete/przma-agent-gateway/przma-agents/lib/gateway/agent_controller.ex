# lib/gateway/agent_controller.ex
#
# REST API controller for agent services.
# All endpoints require DID authentication (conn.assigns.did).

defmodule PRZMAWeb.AgentController do
  use PRZMAWeb, :controller

  alias PRZMA.Agents.{Gateway, Registry, ToolGrantManager, ExecutionLog}

  # ── SESSION LIFECYCLE ─────────────────────────────────────────────────────

  # POST /api/v1/agents/sessions
  def create_session(conn, params) do
    did = conn.assigns.did

    opts = [
      agent_type:   parse_agent_type(params["agent_type"]),
      context_uri:  params["context_uri"],
      tool_grants:  params["tool_grants"] || [],
      circle_did:   params["circle_did"],
      input:        params["input"] || "",
      stream:       params["stream"] == true,
    ]

    case Gateway.start_session(did, opts) do
      {:ok, result} ->
        conn |> put_status(:created) |> json(result)

      {:error, {:tier_required, tier, msg}} ->
        conn |> put_status(:payment_required) |> json(%{
          error:     "tier_required",
          required:  tier,
          message:   msg,
          upgrade:   "https://przma.app/upgrade",
        })

      {:error, {:rate_limited, msg}} ->
        conn |> put_status(429) |> json(%{error: "rate_limited", message: msg})

      {:error, {:unknown_agent_type, type}} ->
        conn |> put_status(:bad_request) |> json(%{
          error:   "unknown_agent_type",
          type:    type,
          available: Enum.map(Registry.list(), & &1.type),
        })

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v1/agents/sessions
  def list_sessions(conn, _params) do
    did      = conn.assigns.did
    sessions = Gateway.list_sessions(did)
    json(conn, %{sessions: sessions, count: length(sessions)})
  end

  # GET /api/v1/agents/sessions/:session_id
  def get_session(conn, %{"session_id" => session_id}) do
    did = conn.assigns.did
    case Gateway.get_session(did, session_id) do
      {:ok, state}              -> json(conn, state)
      {:error, :not_found}      -> conn |> put_status(:not_found) |> json(%{error: "session_not_found"})
      {:error, :not_your_session} -> conn |> put_status(:forbidden) |> json(%{error: "not_your_session"})
    end
  end

  # DELETE /api/v1/agents/sessions/:session_id
  def stop_session(conn, %{"session_id" => session_id}) do
    did = conn.assigns.did
    case Gateway.stop_session(did, session_id) do
      :ok            -> conn |> put_status(:no_content) |> send_resp(204, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "session_not_found"})
      {:error, reason}     -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v1/agents/sessions/:session_id/pause
  def pause_session(conn, %{"session_id" => session_id}) do
    did = conn.assigns.did
    case Gateway.pause_session(did, session_id) do
      :ok            -> json(conn, %{status: :paused})
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v1/agents/sessions/:session_id/resume
  def resume_session(conn, %{"session_id" => session_id}) do
    did = conn.assigns.did
    case Gateway.resume_session(did, session_id) do
      :ok            -> json(conn, %{status: :running})
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # POST /api/v1/agents/sessions/:session_id/message
  def send_message(conn, %{"session_id" => session_id, "content" => content}) do
    did = conn.assigns.did
    case Gateway.send_message(did, session_id, content) do
      :ok              -> json(conn, %{received: true})
      {:error, reason} -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v1/agents/sessions/:session_id/log
  def execution_log(conn, %{"session_id" => session_id} = params) do
    did   = conn.assigns.did
    limit = String.to_integer(params["limit"] || "50")

    case Gateway.execution_log(did, session_id, limit: limit) do
      {:ok, entries}    -> json(conn, %{entries: entries, count: length(entries)})
      {:error, reason}  -> conn |> put_status(:bad_request) |> json(%{error: inspect(reason)})
    end
  end

  # GET /api/v1/agents/sessions/:session_id/output  (SSE stream)
  def stream_output(conn, %{"session_id" => session_id}) do
    did = conn.assigns.did

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # Subscribe to session channel and relay events as SSE
    PRZMAWeb.Endpoint.subscribe("agent:session:#{session_id}")

    stream_loop(conn, did, session_id)
  end

  # ── REGISTRY ─────────────────────────────────────────────────────────────

  # GET /api/v1/agents/registry
  def list_registry(conn, _params) do
    did    = conn.assigns.did
    tier   = PRZMA.Deployment.License.did_tier(did)
    agents = Registry.list(tier)

    json(conn, %{
      agents: Enum.map(agents, fn a ->
        Map.take(a, [:type, :name, :description, :tools, :min_tier, :streaming])
        |> Map.put(:available, true)
      end),
      tier:  tier,
      count: length(agents),
    })
  end

  # ── TOOL GRANTS ──────────────────────────────────────────────────────────

  # GET /api/v1/agents/tool-grants
  def list_tool_grants(conn, _params) do
    did    = conn.assigns.did
    grants = ToolGrantManager.active_grants(did)
    json(conn, %{grants: grants, count: length(grants)})
  end

  # GET /api/v1/agents/tool-catalogue
  def tool_catalogue(conn, _params) do
    json(conn, %{tools: ToolGrantManager.catalogue()})
  end

  # ── USAGE ────────────────────────────────────────────────────────────────

  # GET /api/v1/agents/usage
  def usage(conn, _params) do
    did      = conn.assigns.did
    tier     = PRZMA.Deployment.License.did_tier(did)
    sessions = Gateway.list_sessions(did)

    json(conn, %{
      tier:             tier,
      active_sessions:  length(sessions),
      max_sessions:     Registry.max_sessions(tier),
      tool_grants:      length(ToolGrantManager.active_grants(did)),
    })
  end

  # ── SSE STREAM LOOP ───────────────────────────────────────────────────────

  defp stream_loop(conn, did, session_id) do
    receive do
      %Phoenix.Socket.Broadcast{event: "agent:output", payload: payload} ->
        data = Jason.encode!(payload)
        case Plug.Conn.chunk(conn, "data: #{data}\n\n") do
          {:ok, conn}  -> stream_loop(conn, did, session_id)
          {:error, _}  -> :closed
        end

      %Phoenix.Socket.Broadcast{event: "agent:complete"} ->
        Plug.Conn.chunk(conn, "data: {\"type\":\"complete\"}\n\n")
        conn

      %Phoenix.Socket.Broadcast{event: "agent:error", payload: payload} ->
        data = Jason.encode!(payload)
        Plug.Conn.chunk(conn, "data: #{data}\n\n")
        conn

      _other ->
        stream_loop(conn, did, session_id)

    after
      60_000 ->
        # Heartbeat to keep connection alive
        case Plug.Conn.chunk(conn, ": keepalive\n\n") do
          {:ok, conn}  -> stream_loop(conn, did, session_id)
          {:error, _}  -> :closed
        end
    end
  end

  defp parse_agent_type(nil),   do: :companion
  defp parse_agent_type(str),   do: String.to_existing_atom(str)
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/session/execution_log.ex
#
# Execution log — every tool call in every session stored in Lance.
# pzdb://did/agents/core/execution_log/{step_id}

defmodule PRZMA.Agents.ExecutionLog do
  alias PRZMA.PzDb
  require Logger

  def append(session_id, did, entry) do
    step_id = "#{session_id}_step_#{entry.step}"
    uri     = "pzdb://#{did}/agents/core/execution_log/#{step_id}"

    record = %{
      "id"             => step_id,
      "did"            => did,
      "session_id"     => session_id,
      "step"           => entry.step,
      "tool"           => entry.tool,
      "input_cas"      => nil,
      "output_cas"     => nil,
      "input_json"     => entry[:input_json]  || "{}",
      "output_json"    => entry[:output_json] || "{}",
      "status"         => to_string(entry[:status] || :ok),
      "error_message"  => entry[:error_message],
      "latency_ms"     => entry[:latency_ms] || 0,
      "executed_at"    => entry[:executed_at] || System.os_time(:microsecond),
    }

    PzDb.write(uri, record, encrypt: false)
  end

  def list(session_id, opts \\ []) do
    # We'd need to know the DID to query — in practice this is passed in
    # For now: return from the session's cached state
    limit = opts[:limit] || 50
    {:ok, []}   # Phase final: query execution_log.lance for session_id
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/gateway/agent_application_supervisor.ex
#
# Top-level supervisor for all agent gateway components.
# Add to application.ex after PRZMA.PzDb.Supervisor.

defmodule PRZMA.Agents.ApplicationSupervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for AgentSession GenServers
      {Registry, keys: :unique, name: PRZMA.Agents.SessionRegistry},

      # Agent type registry (ETS-backed)
      PRZMA.Agents.Registry,

      # Tool grant store (ETS-backed)
      %{id: PRZMA.Agents.ToolGrantManager,
        start: {PRZMA.Agents.ToolGrantManager, :start_link, []}},

      # Rate limiter (ETS-backed)
      %{id: PRZMA.Agents.RateLimiter,
        start: {PRZMA.Agents.RateLimiter, :start_link, []}},

      # Session supervisor (DynamicSupervisor)
      PRZMA.Agents.Supervisor,
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# Router scope — add to PRZMAWeb.Router under :require_did_auth scope:
#
# scope "/api/v1/agents", PRZMAWeb do
#   pipe_through [:api, :require_did_auth]
#
#   # Registry & catalogue
#   get    "/registry",                           AgentController, :list_registry
#   get    "/tool-catalogue",                     AgentController, :tool_catalogue
#   get    "/usage",                              AgentController, :usage
#   get    "/tool-grants",                        AgentController, :list_tool_grants
#
#   # Session lifecycle
#   post   "/sessions",                           AgentController, :create_session
#   get    "/sessions",                           AgentController, :list_sessions
#   get    "/sessions/:session_id",               AgentController, :get_session
#   delete "/sessions/:session_id",               AgentController, :stop_session
#   post   "/sessions/:session_id/message",       AgentController, :send_message
#   post   "/sessions/:session_id/pause",         AgentController, :pause_session
#   post   "/sessions/:session_id/resume",        AgentController, :resume_session
#   get    "/sessions/:session_id/log",           AgentController, :execution_log
#   get    "/sessions/:session_id/output",        AgentController, :stream_output
# end
#
# WebSocket channel — add to PRZMAWeb.UserSocket:
#   channel "agent:session:*", PRZMAWeb.AgentChannel
