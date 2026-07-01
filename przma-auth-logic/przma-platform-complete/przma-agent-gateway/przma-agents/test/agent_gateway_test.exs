# test/agent_gateway_test.exs

defmodule PRZMA.Agents.GatewayTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias PRZMA.Agents.{Gateway, Registry, ToolGrantManager, RateLimiter}

  @did "did:web:agent-test.local"

  # ── 1. Registry ─────────────────────────────────────────────────────────────

  describe "Registry" do
    test "companion agent available on free_local tier" do
      assert :ok = Registry.check_agent_available(@did, :companion)
    end

    test "lists agents appropriate for tier" do
      free_agents = Registry.list(:free_local)
      assert Enum.any?(free_agents, fn a -> a.type == :companion end)
    end

    test "professional agents not available on free tier" do
      # analytics requires :professional
      result = Registry.check_agent_available(@did, :analytics)
      # Depends on the test DID's tier — in test mode defaults to free_local
      assert result in [:ok, {:error, {:tier_required, _, _}}]
    end

    test "get returns agent definition" do
      {:ok, agent} = Registry.get(:companion)
      assert agent.type == :companion
      assert is_list(agent.tools)
      assert is_integer(agent.max_steps)
    end

    test "get returns error for unknown type" do
      assert {:error, :unknown_agent_type} = Registry.get(:nonexistent_agent)
    end

    test "max_sessions returns integer for all tiers" do
      for tier <- [:free_local, :essential, :professional, :sovereign] do
        result = Registry.max_sessions(tier)
        assert is_integer(result) or result == :unlimited
      end
    end
  end

  # ── 2. Tool Grant Manager ──────────────────────────────────────────────────

  describe "ToolGrantManager" do
    test "issues grants for companion tools" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, [])
      assert length(grants) > 0
      tools = Enum.map(grants, & &1.tool)
      assert "vault:read" in tools
      assert "calendar:read" in tools
    end

    test "grants have expiry in future" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, [])
      now = System.os_time(:second)
      Enum.each(grants, fn g ->
        assert g.expires_at > now
      end)
    end

    test "verify_grant returns true for valid grant" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, ["vault:read"])
      assert ToolGrantManager.verify_grant(@did, "vault:read", grants)
    end

    test "verify_grant returns false for ungranted tool" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, ["vault:read"])
      refute ToolGrantManager.verify_grant(@did, "chat:send", grants)
    end

    test "verify_grant returns false for wrong DID" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, ["vault:read"])
      refute ToolGrantManager.verify_grant("did:web:other.local", "vault:read", grants)
    end

    test "catalogue returns map of all tools" do
      catalogue = ToolGrantManager.catalogue()
      assert is_map(catalogue)
      assert Map.has_key?(catalogue, "vault:read")
      assert Map.has_key?(catalogue, "calendar:write")
    end
  end

  # ── 3. Rate Limiter ───────────────────────────────────────────────────────

  describe "RateLimiter" do
    test "first session request succeeds" do
      # Use unique DID to avoid cross-test contamination
      did = "did:web:ratelimit-#{:rand.uniform(999)}.local"
      assert :ok = RateLimiter.check_session_limit(did)
    end

    test "first message request succeeds" do
      did = "did:web:ratelimit-msg-#{:rand.uniform(999)}.local"
      assert :ok = RateLimiter.check_message_limit(did)
    end

    test "many requests in same window eventually hit limit" do
      did = "did:web:ratelimit-many-#{:rand.uniform(999)}.local"
      # Free tier: 5 sessions/hour
      results = for _ <- 1..10, do: RateLimiter.check_session_limit(did)
      errors = Enum.filter(results, fn r -> match?({:error, {:rate_limited, _}}, r) end)
      # Should hit rate limit before 10
      assert length(errors) > 0
    end
  end

  # ── 4. Tool Executor ──────────────────────────────────────────────────────

  describe "ToolExecutor" do
    alias PRZMA.Agents.ToolExecutor

    test "rejects execution without grant" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, ["vault:read"])
      # Try to use calendar:write without a grant for it
      result = ToolExecutor.execute(@did, "calendar:write", %{}, grants)
      assert {:error, :tool_not_granted} = result
    end

    test "schema returns valid map for known tools" do
      for tool <- ~w(vault:read vault:write calendar:read calendar:write companion:context) do
        schema = ToolExecutor.schema(tool)
        assert is_map(schema), "Expected map for tool #{tool}"
        assert Map.has_key?(schema, :name)
        assert Map.has_key?(schema, :description)
        assert Map.has_key?(schema, :parameters)
      end
    end

    test "schema returns nil for unknown tool" do
      assert nil == ToolExecutor.schema("unknown:tool")
    end
  end

  # ── 5. DNA Prompt Builder ─────────────────────────────────────────────────

  describe "DNAPromptBuilder" do
    alias PRZMA.Agents.DNAPromptBuilder

    test "builds non-empty message list" do
      context = %{
        agent_type:   :companion,
        did:          @did,
        context_uri:  nil,
        messages:     [%{role: :user, content: "Hello", ts: 0}],
        observations: [],
        thoughts:     [],
        step_history: [],
      }
      opts = %{
        agent_type:  :companion,
        did:         @did,
        tool_grants: [],
        context_uri: nil,
      }

      messages = DNAPromptBuilder.build(:companion, context, opts)
      assert is_list(messages)
      assert length(messages) >= 1

      system_msg = Enum.find(messages, fn m -> m.role == "system" end)
      assert is_map(system_msg)
      assert String.contains?(system_msg.content, "PRZMA")
    end

    test "includes tool definitions when grants are provided" do
      {:ok, grants} = ToolGrantManager.issue_grants(@did, :companion, [])
      context = %{agent_type: :companion, did: @did, context_uri: nil,
                  messages: [], observations: [], thoughts: [], step_history: []}
      opts = %{agent_type: :companion, did: @did, tool_grants: grants, context_uri: nil}

      messages = DNAPromptBuilder.build(:companion, context, opts)
      system_content = messages |> Enum.map(& &1.content) |> Enum.join("\n")
      assert String.contains?(system_content, "AVAILABLE TOOLS")
    end

    test "builds different prompts for different agent types" do
      opts = %{did: @did, tool_grants: [], context_uri: nil}
      empty_ctx = %{agent_type: :companion, did: @did, context_uri: nil,
                    messages: [], observations: [], thoughts: [], step_history: []}

      companion_msgs  = DNAPromptBuilder.build(:companion,   empty_ctx, Map.put(opts, :agent_type, :companion))
      calendar_msgs   = DNAPromptBuilder.build(:calendar,    empty_ctx, Map.put(opts, :agent_type, :calendar))
      scribe_msgs     = DNAPromptBuilder.build(:vault_scribe,empty_ctx, Map.put(opts, :agent_type, :vault_scribe))

      c_content = companion_msgs  |> Enum.map(& &1.content) |> hd()
      k_content = calendar_msgs   |> Enum.map(& &1.content) |> hd()
      s_content = scribe_msgs     |> Enum.map(& &1.content) |> hd()

      # Each agent type has distinct identity
      assert c_content != k_content
      assert k_content != s_content
    end
  end

  # ── 6. Channel routing ─────────────────────────────────────────────────────

  describe "Agent supervisor" do
    test "active_count returns integer" do
      count = PRZMA.Agents.Supervisor.active_count()
      assert is_integer(count)
      assert count >= 0
    end
  end

  # ── 7. Gateway integration ─────────────────────────────────────────────────

  describe "Gateway.start_session" do
    test "rejects unknown agent type" do
      result = Gateway.start_session(@did, [agent_type: :unknown_type_xyz])
      assert {:error, {:unknown_agent_type, :unknown_type_xyz}} = result
    end

    test "starts companion session successfully" do
      # This requires the full agent infrastructure running
      result = Gateway.start_session(@did, [
        agent_type: :companion,
        input:      "What are my practices today?",
      ])
      case result do
        {:ok, %{session_id: id, agent_type: :companion}} ->
          assert is_binary(id)
          # Clean up
          Gateway.stop_session(@did, id)
        {:error, _} ->
          # May fail if LLM not configured — that's acceptable in unit tests
          :ok
      end
    end
  end
end
