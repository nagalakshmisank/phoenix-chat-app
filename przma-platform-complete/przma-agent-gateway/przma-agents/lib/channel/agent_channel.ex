# lib/loop/llm_adapter.ex
#
# LLM Adapter — routes agent prompts to the configured inference backend.
#
# Backends (configured via PRZMA_LLM_BACKEND env var):
#   :local     — TFLite/ONNX on-device (sovereign, no network, limited capability)
#   :openai    — OpenAI-compatible API (cloud, powerful, requires API key)
#   :anthropic — Anthropic Claude API (cloud, powerful, requires API key)
#   :ollama    — Ollama local server (self-hosted LLM, sovereign)
#
# Response parsing follows a structured ReAct format:
#   THOUGHT: <reasoning>
#   ACTION: <tool_name>
#   INPUT: <json>
#   — or —
#   FINAL: <response>

defmodule PRZMA.Agents.LLMAdapter do
  require Logger

  @backend Application.compile_env(:przma, [:agents, :llm_backend], :anthropic)

  @doc """
  Call the configured LLM with the DNA prompt.
  Returns:
    {:ok, %{type: :tool_call,      tool: name, input: map}}
    {:ok, %{type: :thinking,       content: string}}
    {:ok, %{type: :final_response, content: string}}
    {:error, reason}
  """
  def call(messages, tool_grants) do
    case @backend do
      :anthropic -> call_anthropic(messages, tool_grants)
      :openai    -> call_openai(messages, tool_grants)
      :ollama    -> call_ollama(messages)
      :local     -> call_local(messages)
      _          -> call_mock(messages)
    end
  end

  # ── ANTHROPIC BACKEND ─────────────────────────────────────────────────────

  defp call_anthropic(messages, tool_grants) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || return({:error, :no_api_key})

    tools   = build_anthropic_tools(tool_grants)
    system  = extract_system(messages)
    msgs    = to_anthropic_messages(messages)

    body = %{
      model:      System.get_env("PRZMA_LLM_MODEL", "claude-sonnet-4-5"),
      max_tokens: 2048,
      system:     system,
      messages:   msgs,
      tools:      tools,
    }

    case Finch.build(:post, "https://api.anthropic.com/v1/messages",
          [
            {"Content-Type", "application/json"},
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"},
          ],
          Jason.encode!(body)
        )
        |> Finch.request(PRZMA.Finch, receive_timeout: 60_000) do

      {:ok, %Finch.Response{status: 200, body: body}} ->
        parse_anthropic_response(Jason.decode!(body))

      {:ok, %Finch.Response{status: s, body: body}} ->
        {:error, {:api_error, s, body}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp parse_anthropic_response(%{"content" => content}) when is_list(content) do
    # Find tool_use or text blocks
    tool_use = Enum.find(content, fn c -> c["type"] == "tool_use" end)
    text     = Enum.find(content, fn c -> c["type"] == "text" end)

    cond do
      tool_use ->
        {:ok, %{
          type:  :tool_call,
          tool:  tool_use["name"],
          input: tool_use["input"] || %{},
        }}
      text ->
        parse_react_text(text["text"])
      true ->
        {:ok, %{type: :final_response, content: "No response generated."}}
    end
  end
  defp parse_anthropic_response(_), do: {:ok, %{type: :final_response, content: "Unexpected response format."}}

  defp build_anthropic_tools(tool_grants) do
    tool_grants
    |> Enum.map(fn grant ->
        schema = PRZMA.Agents.ToolExecutor.schema(grant.tool)
        if schema do
          %{
            name:        schema.name,
            description: schema.description,
            input_schema: schema.parameters,
          }
        end
      end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_system(messages) do
    messages
    |> Enum.filter(fn m -> m.role == "system" end)
    |> Enum.map_join("\n\n", fn m -> m.content end)
  end

  defp to_anthropic_messages(messages) do
    messages
    |> Enum.reject(fn m -> m.role == "system" end)
    |> Enum.map(fn m ->
        %{role: m.role, content: m.content}
      end)
  end

  # ── OLLAMA BACKEND (local sovereign LLM) ──────────────────────────────────

  defp call_ollama(messages) do
    endpoint = System.get_env("OLLAMA_ENDPOINT", "http://localhost:11434")
    model    = System.get_env("PRZMA_LLM_MODEL", "llama3.2")

    prompt = messages
      |> Enum.map(fn m -> "#{String.upcase(m.role)}: #{m.content}" end)
      |> Enum.join("\n\n")

    body = Jason.encode!(%{model: model, prompt: prompt, stream: false})

    case Finch.build(:post, "#{endpoint}/api/generate",
          [{"Content-Type", "application/json"}], body)
        |> Finch.request(PRZMA.Finch, receive_timeout: 120_000) do

      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, %{"response" => text}} -> parse_react_text(text)
          _ -> {:error, :invalid_ollama_response}
        end

      {:ok, %Finch.Response{status: s}} ->
        {:error, {:ollama_error, s}}

      {:error, reason} ->
        {:error, {:ollama_unreachable, reason}}
    end
  end

  # ── LOCAL (on-device TFLite) ──────────────────────────────────────────────

  defp call_local(_messages) do
    # Phase final: route to TFLite inference via NIF
    # For now: structured mock that demonstrates the format
    {:ok, %{
      type:    :final_response,
      content: "Local inference is being configured. Please set PRZMA_LLM_BACKEND=anthropic or PRZMA_LLM_BACKEND=ollama in your configuration.",
    }}
  end

  # ── OPENAI BACKEND ────────────────────────────────────────────────────────

  defp call_openai(messages, tool_grants) do
    api_key = System.get_env("OPENAI_API_KEY") || return({:error, :no_api_key})
    model   = System.get_env("PRZMA_LLM_MODEL", "gpt-4o-mini")

    tools = build_openai_tools(tool_grants)
    msgs  = messages |> Enum.map(fn m -> %{role: m.role, content: m.content} end)

    body = %{model: model, messages: msgs, tools: tools, max_tokens: 2048}

    case Finch.build(:post, "https://api.openai.com/v1/chat/completions",
          [{"Content-Type", "application/json"}, {"Authorization", "Bearer #{api_key}"}],
          Jason.encode!(body))
        |> Finch.request(PRZMA.Finch, receive_timeout: 60_000) do

      {:ok, %Finch.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"choices" => [%{"message" => msg} | _]}} ->
            case msg["tool_calls"] do
              [%{"function" => %{"name" => name, "arguments" => args_json}} | _] ->
                {:ok, %{type: :tool_call, tool: name, input: Jason.decode!(args_json)}}
              _ ->
                parse_react_text(msg["content"] || "")
            end
          _ -> {:error, :invalid_openai_response}
        end

      {:ok, %Finch.Response{status: s, body: b}} ->
        {:error, {:openai_error, s, b}}

      {:error, reason} ->
        {:error, {:network_error, reason}}
    end
  end

  defp build_openai_tools(tool_grants) do
    tool_grants
    |> Enum.map(fn grant ->
        schema = PRZMA.Agents.ToolExecutor.schema(grant.tool)
        if schema do
          %{type: "function", function: %{
            name:        schema.name,
            description: schema.description,
            parameters:  schema.parameters,
          }}
        end
      end)
    |> Enum.reject(&is_nil/1)
  end

  # ── MOCK (development) ────────────────────────────────────────────────────

  defp call_mock(messages) do
    last = messages |> List.last() |> Map.get(:content, "")
    {:ok, %{
      type:    :final_response,
      content: "Mock LLM response to: #{String.slice(last, 0, 100)}. Configure PRZMA_LLM_BACKEND to use a real LLM.",
    }}
  end

  # ── REACT PARSER ─────────────────────────────────────────────────────────

  defp parse_react_text(text) when is_binary(text) do
    cond do
      text =~ ~r/^ACTION:\s*(.+)/mi ->
        [_, tool] = Regex.run(~r/^ACTION:\s*(.+)/mi, text)
        input = case Regex.run(~r/^INPUT:\s*(.+)/ms, text) do
          [_, inp] -> Jason.decode(inp) |> elem(1) rescue _ -> %{}
          nil      -> %{}
        end
        {:ok, %{type: :tool_call, tool: String.trim(tool), input: input}}

      text =~ ~r/^THOUGHT:\s*(.+)/mi ->
        [_, thought] = Regex.run(~r/^THOUGHT:\s*(.+)/mi, text)
        {:ok, %{type: :thinking, content: String.trim(thought)}}

      text =~ ~r/^FINAL:\s*(.+)/ms ->
        [_, final] = Regex.run(~r/^FINAL:\s*(.+)/ms, text)
        {:ok, %{type: :final_response, content: String.trim(final)}}

      true ->
        {:ok, %{type: :final_response, content: String.trim(text)}}
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/rate_limit/agent_rate_limiter.ex
#
# Token-bucket rate limiter for agent API.
# Limits: sessions per hour, messages per minute, all per DID.

defmodule PRZMA.Agents.RateLimiter do
  @table :przma_agent_rate_limits

  # Limits per tier
  @sessions_per_hour  %{free_local: 5,  essential: 20,  professional: 100,  sovereign: 1_000}
  @messages_per_min   %{free_local: 10, essential: 30,  professional: 100,  sovereign: 1_000}

  def start_link(_opts \\ []) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, :ets_only}
  end

  def check_session_limit(did) do
    tier    = PRZMA.Deployment.License.did_tier(did)
    limit   = Map.get(@sessions_per_hour, tier, 5)
    window  = :os.system_time(:second)    |> div(3600)  # hourly window
    key     = {did, :sessions, window}
    check_and_increment(key, limit)
  end

  def check_message_limit(did) do
    tier    = PRZMA.Deployment.License.did_tier(did)
    limit   = Map.get(@messages_per_min, tier, 10)
    window  = :os.system_time(:second) |> div(60)  # per-minute window
    key     = {did, :messages, window}
    check_and_increment(key, limit)
  end

  defp check_and_increment(key, limit) do
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})
    if count <= limit do
      :ok
    else
      {:error, {:rate_limited, "Limit #{limit} exceeded. Try again next window."}}
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/session/agent_supervisor.ex
#
# DynamicSupervisor for agent sessions.
# Each session is a temporary GenServer — stopped when the session completes.

defmodule PRZMA.Agents.Supervisor do
  use DynamicSupervisor
  require Logger

  @sessions_table :przma_agent_sessions

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@sessions_table, [:set, :public, :named_table, write_concurrency: true])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start a new agent session. Returns {:ok, session_id}."
  def start_session(did, opts) do
    session_id = generate_session_id()

    spec = %{
      id:       session_id,
      start:    {PRZMA.Agents.Session, :start_link, [{session_id, did, opts}]},
      restart:  :temporary,
      type:     :worker,
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        :ets.insert(@sessions_table, {session_id, %{did: did, started_at: System.os_time(:microsecond)}})
        Logger.info("Agent session started", session_id: session_id, did: did, type: opts.agent_type)
        {:ok, session_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "List active session IDs for a DID."
  def sessions_for(did) do
    @sessions_table
    |> :ets.tab2list()
    |> Enum.filter(fn {_, meta} -> meta.did == did end)
    |> Enum.map(fn {id, meta} ->
        case PRZMA.Agents.Session.get_state(id) do
          {:ok, state} -> Map.merge(meta, state)
          _            -> nil
        end
      end)
    |> Enum.reject(&is_nil/1)
  end

  @doc "Count of active sessions across all DIDs."
  def active_count do
    :ets.info(@sessions_table, :size)
  end

  defp generate_session_id do
    "session_#{:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)}"
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/channel/agent_channel.ex
#
# Phoenix WebSocket channel for real-time agent communication.
# Clients subscribe to "agent:session:{session_id}" for live output.

defmodule PRZMAWeb.AgentChannel do
  use PRZMAWeb, :channel
  require Logger

  alias PRZMA.Agents.{Gateway, Session}

  # Client connects: "agent:session:session_123abc"
  @impl true
  def join("agent:session:" <> session_id, _params, socket) do
    did = socket.assigns.did

    case Session.get_state(session_id) do
      {:ok, state} when state.did == did ->
        # Send buffered output for this session (for late subscribers)
        send(self(), {:send_buffer, state.output_buf})
        {:ok, %{session_id: session_id, status: state.status}, socket}

      {:ok, _other_did} ->
        {:error, %{reason: "not_your_session"}}

      {:error, :not_found} ->
        {:error, %{reason: "session_not_found"}}
    end
  end

  # ── CLIENT MESSAGES ───────────────────────────────────────────────────────

  @impl true
  def handle_in("agent:message", %{"content" => content}, socket) do
    did        = socket.assigns.did
    session_id = extract_session_id(socket.topic)

    case Gateway.send_message(did, session_id, content) do
      :ok            -> {:reply, {:ok, %{received: true}}, socket}
      {:error, msg}  -> {:reply, {:error, %{reason: msg}}, socket}
    end
  end

  def handle_in("agent:start", params, socket) do
    did = socket.assigns.did

    opts = [
      agent_type:   String.to_existing_atom(params["agent_type"] || "companion"),
      context_uri:  params["context_uri"],
      tool_grants:  params["tool_grants"] || [],
      input:        params["input"] || "",
      stream:       true,
    ]

    case Gateway.start_session(did, opts) do
      {:ok, result} ->
        {:reply, {:ok, result}, socket}
      {:error, {reason, msg}} ->
        {:reply, {:error, %{reason: reason, message: msg}}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("agent:pause", _params, socket) do
    did        = socket.assigns.did
    session_id = extract_session_id(socket.topic)
    case Gateway.pause_session(did, session_id) do
      :ok           -> {:reply, {:ok, %{status: :paused}}, socket}
      {:error, msg} -> {:reply, {:error, %{reason: msg}}, socket}
    end
  end

  def handle_in("agent:stop", _params, socket) do
    did        = socket.assigns.did
    session_id = extract_session_id(socket.topic)
    Gateway.stop_session(did, session_id)
    {:reply, {:ok, %{status: :stopped}}, socket}
  end

  # ── BUFFER DELIVERY ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:send_buffer, []}, socket), do: {:noreply, socket}
  def handle_info({:send_buffer, buffer}, socket) do
    # Replay buffered output for late subscribers
    buffer
    |> Enum.reverse()
    |> Enum.each(fn chunk ->
        push(socket, "agent:output", %{chunk: chunk, buffered: true})
      end)
    {:noreply, socket}
  end

  defp extract_session_id("agent:session:" <> id), do: id
  defp extract_session_id(_), do: nil
end
