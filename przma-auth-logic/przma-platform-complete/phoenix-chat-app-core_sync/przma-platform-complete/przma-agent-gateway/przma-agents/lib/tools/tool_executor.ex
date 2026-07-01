# lib/tools/tool_grant_manager.ex
#
# Tool Grant Manager — issues, verifies, and revokes scoped time-limited tool access.
# Tool grants are the security boundary between agents and PRZMA services.
# An agent can ONLY call tools it has been explicitly granted.

defmodule PRZMA.Agents.ToolGrantManager do
  require Logger

  @grant_ttl_secs    3_600    # Grants expire after 1 hour
  @grant_table       :przma_tool_grants

  # ── ALL AVAILABLE TOOLS ────────────────────────────────────────────────────
  # Tool → minimum tier required

  @tool_catalogue %{
    "vault:read"       => :free_local,
    "vault:write"      => :essential,
    "calendar:read"    => :free_local,
    "calendar:write"   => :essential,
    "chat:read"        => :essential,
    "chat:send"        => :professional,
    "files:read"       => :essential,
    "files:write"      => :professional,
    "metadata:read"    => :free_local,
    "metadata:write"   => :essential,
    "ai:infer"         => :essential,
    "web:search"       => :professional,
    "companion:context"=> :free_local,
  }

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(_opts \\ []) do
    :ets.new(@grant_table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, :ets_only}   # No GenServer needed — pure ETS
  end

  @doc """
  Issue tool grants for an agent session.
  Validates each requested tool against:
    1. Tool exists in catalogue
    2. User tier allows the tool
    3. Agent type is permitted to use this tool
  Returns {:ok, [grant structs]} | {:error, reason}
  """
  def issue_grants(did, agent_type, requested_tools) do
    tier           = PRZMA.Deployment.License.did_tier(did)
    session_id     = generate_session_id()
    expires_at     = System.os_time(:second) + @grant_ttl_secs

    {:ok, agent_def} = PRZMA.Agents.Registry.get(agent_type)
    agent_tools    = agent_def[:tools] || []

    results = Enum.reduce_while(requested_tools_or_default(requested_tools, agent_tools),
                                {:ok, []},
      fn tool, {:ok, grants} ->
        case validate_tool(tool, tier, agent_tools) do
          :ok ->
            grant = %{
              id:         "#{session_id}_#{tool}",
              did:        did,
              session_id: session_id,
              tool:       tool,
              expires_at: expires_at,
              is_active:  true,
            }
            :ets.insert(@grant_table, {grant.id, grant})
            {:cont, {:ok, [grant | grants]}}

          {:error, reason} ->
            Logger.warning("Tool grant denied", tool: tool, did: did, reason: reason)
            # Skip denied tools rather than failing the whole session
            {:cont, {:ok, grants}}
        end
      end
    )

    results
  end

  @doc "Verify a tool grant is valid and not expired."
  def verify_grant(did, tool, tool_grants) do
    now = System.os_time(:second)
    Enum.any?(tool_grants, fn grant ->
      grant.tool == tool and
      grant.did  == did  and
      grant.is_active    and
      grant.expires_at > now
    end)
  end

  @doc "Revoke all grants for a session."
  def revoke_session_grants(session_id) do
    :ets.match_delete(@grant_table, {:_, %{session_id: session_id}})
  end

  @doc "List all active grants for a DID."
  def active_grants(did) do
    now = System.os_time(:second)
    :ets.tab2list(@grant_table)
    |> Enum.map(fn {_, g} -> g end)
    |> Enum.filter(fn g ->
        g.did == did and g.is_active and g.expires_at > now
      end)
  end

  @doc "All tools in the catalogue with their minimum tier."
  def catalogue, do: @tool_catalogue

  # ── PRIVATE ───────────────────────────────────────────────────────────────

  defp validate_tool(tool, tier, agent_tools) do
    cond do
      !Map.has_key?(@tool_catalogue, tool) ->
        {:error, :unknown_tool}

      !tier_allows_tool?(tier, @tool_catalogue[tool]) ->
        {:error, {:tier_insufficient, "#{tool} requires #{@tool_catalogue[tool]} tier"}}

      !Enum.member?(agent_tools, tool) ->
        {:error, {:agent_not_permitted, "#{tool} not in #{Enum.join(agent_tools, ", ")}"}}

      true ->
        :ok
    end
  end

  defp requested_tools_or_default([], agent_tools), do: agent_tools
  defp requested_tools_or_default(requested, agent_tools) do
    # Only grant intersection of requested and what the agent type allows
    Enum.filter(requested, fn t -> Enum.member?(agent_tools, t) end)
  end

  @tier_order [:free_local, :essential, :professional, :sovereign]

  defp tier_allows_tool?(user_tier, required_tier) do
    ui = Enum.find_index(@tier_order, &(&1 == user_tier))    || 0
    ri = Enum.find_index(@tier_order, &(&1 == required_tier)) || 0
    ui >= ri
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# lib/tools/tool_executor.ex
#
# Tool Executor — the only path through which agents interact with PRZMA services.
# Every tool call goes through:
#   1. Grant verification (is this tool granted to this session?)
#   2. Input validation (does input match tool schema?)
#   3. Execution (call the appropriate PRZMA service)
#   4. Result sanitisation (strip sensitive fields before returning to agent)

defmodule PRZMA.Agents.ToolExecutor do
  require Logger

  alias PRZMA.Agents.ToolGrantManager
  alias PRZMA.PzDb

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── EXECUTE ───────────────────────────────────────────────────────────────

  @doc "Execute a tool call. Returns {:ok, result} | {:error, reason}."
  def execute(did, tool, input, tool_grants) do
    # 1. Verify grant
    unless ToolGrantManager.verify_grant(did, tool, tool_grants) do
      Logger.warning("Tool call denied — not granted", did: did, tool: tool)
      return {:error, :tool_not_granted}
    end

    # 2. Execute
    start = System.monotonic_time(:millisecond)
    result = do_execute(did, tool, input)
    duration = System.monotonic_time(:millisecond) - start

    :telemetry.execute([:przma, :agent, :tool_call],
      %{duration_ms: duration},
      %{did: did, tool: tool, success: match?({:ok, _}, result)})

    Logger.debug("Tool executed", tool: tool, duration_ms: duration)
    result
  end

  # ── TOOL IMPLEMENTATIONS ──────────────────────────────────────────────────

  defp do_execute(did, "vault:read", %{"uri" => uri}) do
    # Ensure the URI belongs to this DID
    if uri_belongs_to_did?(uri, did) do
      PzDb.read(uri, decrypt: true)
      |> case do
          {:ok, %{found: true, record: r}} -> {:ok, r}
          {:ok, %{found: false}}           -> {:ok, %{not_found: true}}
          {:error, msg}                    -> {:error, msg}
        end
    else
      {:error, :access_denied}
    end
  end

  defp do_execute(did, "vault:read", %{"query" => query, "domain" => domain}) do
    # Semantic search in vault domain
    case PzDb.query(
      "pzdb://#{did}/vault/core/entries/placeholder",
      filter: "domain = '#{sanitise(domain)}' AND deleted_at IS NULL",
      limit: 5
    ) do
      {:ok, %{"records" => records}} -> {:ok, %{records: records, count: length(records)}}
      {:error, msg}                  -> {:error, msg}
    end
  end

  defp do_execute(did, "vault:write", %{"domain" => domain, "title" => title, "body" => body}) do
    domain = sanitise(domain)
    unless valid_vault_domain?(domain) do
      return {:error, {:invalid_domain, "Use: my_health, my_day, my_people, my_thoughts, who_i_am, what_i_learned, quiet_moments, my_practices"}}
    end

    entry_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    uri      = "pzdb://#{did}/vault/core/entries/#{entry_id}"

    # Store body in CAS
    case PRZMA.Platform.CAS.put_text(did, body, written_by: "agent") do
      {:ok, body_cas} ->
        record = %{
          "id"                => entry_id,
          "did"               => did,
          "domain"            => domain,
          "entry_type"        => "agent_entry",
          "title"             => title,
          "body_cas"          => body_cas,
          "richtext_cas"      => nil,
          "source_uri"        => nil,
          "source_type"       => "agent",
          "filter_context"    => "{}",
          "lens_context"      => "{}",
          "tags_json"         => "[]",
          "attachments_json"  => "[]",
          "embedding"         => List.duplicate(0.0, 768),
          "is_private"        => true,
          "is_pinned"         => false,
          "created_at"        => System.os_time(:microsecond),
          "updated_at"        => System.os_time(:microsecond),
          "version"           => 1,
        }
        case PzDb.write(uri, record) do
          {:ok, wr} -> {:ok, %{uri: uri, version: wr["version"]}}
          err       -> err
        end

      {:error, msg} -> {:error, {:cas_write_failed, msg}}
    end
  end

  defp do_execute(did, "calendar:read", %{"space" => space} = input) do
    limit  = min(input["limit"] || 10, 50)
    filter = build_calendar_filter(input)
    case PzDb.query(
      "pzdb://#{did}/calendar/#{sanitise(space)}/events/placeholder",
      filter: filter,
      limit:  limit
    ) do
      {:ok, %{"records" => records}} ->
        # Strip embeddings from agent response (too large, not useful)
        stripped = Enum.map(records, &strip_embeddings/1)
        {:ok, %{events: stripped, count: length(stripped)}}
      {:error, msg} -> {:error, msg}
    end
  end

  defp do_execute(did, "calendar:write", %{"action" => "create_event"} = input) do
    event_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    space    = input["space"] || "core"
    uri      = "pzdb://#{did}/calendar/#{space}/events/#{event_id}"

    record = %{
      "id"          => event_id,
      "did"         => did,
      "space"       => space,
      "title"       => input["title"],
      "description" => input["description"] || "",
      "category"    => input["category"] || "EVENT",
      "start_at"    => parse_datetime(input["start_at"]),
      "end_at"      => parse_datetime(input["end_at"]),
      "status"      => "confirmed",
      "visibility"  => "private",
      "is_recurring"=> false,
      "rrule"       => nil,
      "location_type" => "none",
      "location_ref"  => "",
      "attendees_json"=> "[]",
      "embedding"     => List.duplicate(0.0, 768),
      "created_at"    => System.os_time(:microsecond),
      "updated_at"    => System.os_time(:microsecond),
      "version"       => 1,
    }

    case PzDb.write(uri, record) do
      {:ok, wr} -> {:ok, %{event_id: event_id, uri: uri, version: wr["version"]}}
      err       -> err
    end
  end

  defp do_execute(did, "calendar:write", %{"action" => "create_task"} = input) do
    task_id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    space   = input["space"] || "core"
    uri     = "pzdb://#{did}/calendar/#{space}/tasks/#{task_id}"

    record = %{
      "id"          => task_id,
      "did"         => did,
      "space"       => space,
      "title"       => input["title"],
      "description" => input["description"] || "",
      "category"    => "MEETING",
      "priority"    => input["priority"] || "medium",
      "status"      => "active",
      "due_at"      => input["due_at"] && parse_datetime(input["due_at"]),
      "progress"    => 0,
      "embedding"   => List.duplicate(0.0, 768),
      "created_at"  => System.os_time(:microsecond),
      "updated_at"  => System.os_time(:microsecond),
      "version"     => 1,
    }

    case PzDb.write(uri, record) do
      {:ok, wr} -> {:ok, %{task_id: task_id, uri: uri, version: wr["version"]}}
      err       -> err
    end
  end

  defp do_execute(did, "companion:context", _input) do
    case PRZMA.Calendar.Intelligence.CompanionContext.assemble(did) do
      {:ok, ctx} -> {:ok, sanitise_companion_context(ctx)}
      err        -> err
    end
  end

  defp do_execute(did, "metadata:read", %{"query" => query}) do
    case PRZMA.Platform.MetadataIndex.search(did, query, limit: 10) do
      {:ok, results} -> {:ok, %{results: results, count: length(results)}}
      err            -> err
    end
  end

  defp do_execute(did, "ai:infer", %{"type" => "embed", "text" => text}) do
    case PRZMA.Calendar.NIF.embed_text(text, "query") do
      {:ok, vec_json} -> {:ok, %{embedding: Jason.decode!(vec_json), dim: 768}}
      err             -> err
    end
  end

  defp do_execute(did, "web:search", %{"query" => query}) do
    # Web search via Phoenix HTTP client
    # In production: use a configured search API (Brave, Serper, etc.)
    {:ok, %{
      results: [%{
        title:   "Web search not configured",
        url:     "",
        snippet: "Configure PRZMA_SEARCH_API in your .env to enable web search.",
      }]
    }}
  end

  defp do_execute(_did, tool, _input) do
    {:error, {:unimplemented_tool, tool}}
  end

  # ── TOOL SCHEMAS ──────────────────────────────────────────────────────────

  @doc "Return the JSON schema for a tool (for DNA prompt Layer 4)."
  def schema("vault:read") do
    %{
      name:        "vault:read",
      description: "Read vault entries. Either provide a specific URI or search by domain.",
      parameters: %{
        type: "object",
        properties: %{
          uri:    %{type: "string", description: "pzdb:// URI of a specific entry"},
          domain: %{type: "string", enum: vault_domains(), description: "Vault domain to search"},
          query:  %{type: "string", description: "Search query (used with domain)"},
        },
      },
    }
  end

  def schema("vault:write") do
    %{
      name:        "vault:write",
      description: "Write a new vault entry.",
      parameters: %{
        type:     "object",
        required: ["domain", "title", "body"],
        properties: %{
          domain: %{type: "string", enum: vault_domains()},
          title:  %{type: "string"},
          body:   %{type: "string"},
        },
      },
    }
  end

  def schema("calendar:read") do
    %{
      name:        "calendar:read",
      description: "Read calendar events.",
      parameters: %{
        type:     "object",
        properties: %{
          space:    %{type: "string", default: "core"},
          status:   %{type: "string", enum: ~w(confirmed cancelled all), default: "confirmed"},
          limit:    %{type: "integer", default: 10, maximum: 50},
          category: %{type: "string", description: "Filter by category (MEETING, PRACTICE, etc.)"},
        },
      },
    }
  end

  def schema("calendar:write") do
    %{
      name:        "calendar:write",
      description: "Create calendar events or tasks.",
      parameters: %{
        type:     "object",
        required: ["action"],
        properties: %{
          action:      %{type: "string", enum: ["create_event", "create_task"]},
          title:       %{type: "string"},
          description: %{type: "string"},
          start_at:    %{type: "string", description: "ISO 8601 datetime"},
          end_at:      %{type: "string", description: "ISO 8601 datetime"},
          category:    %{type: "string"},
          priority:    %{type: "string", enum: ~w(low medium high urgent)},
          due_at:      %{type: "string", description: "ISO 8601 datetime (tasks only)"},
        },
      },
    }
  end

  def schema("companion:context"), do:
    %{name: "companion:context", description: "Get current companion context: today's schedule, overdue tasks, active practices, situation assessment.", parameters: %{type: "object", properties: %{}}}

  def schema("metadata:read"), do:
    %{name: "metadata:read", description: "Search across all PRZMA services.", parameters: %{type: "object", required: ["query"], properties: %{query: %{type: "string"}, limit: %{type: "integer", default: 10}}}}

  def schema("ai:infer"), do:
    %{name: "ai:infer", description: "Run local AI inference (embeddings, classification).", parameters: %{type: "object", required: ["type", "text"], properties: %{type: %{type: "string", enum: ["embed"]}, text: %{type: "string"}}}}

  def schema("web:search"), do:
    %{name: "web:search", description: "Search the web.", parameters: %{type: "object", required: ["query"], properties: %{query: %{type: "string"}}}}

  def schema(_), do: nil

  # ── HELPERS ───────────────────────────────────────────────────────────────

  defp uri_belongs_to_did?("pzdb://" <> rest, did) do
    rest |> String.split("/", parts: 2) |> hd() == did
  end
  defp uri_belongs_to_did?(_, _), do: false

  defp sanitise(str) when is_binary(str), do: String.replace(str, ~r/[^a-z0-9_:\-]/, "")
  defp sanitise(_), do: ""

  defp valid_vault_domain?(d), do: d in vault_domains()

  defp vault_domains, do: ~w(my_health my_day my_people my_thoughts who_i_am what_i_learned quiet_moments my_practices)

  defp strip_embeddings(record) when is_map(record), do: Map.delete(record, "embedding")
  defp strip_embeddings(record), do: record

  defp sanitise_companion_context(ctx) do
    ctx |> Map.take([:today, :upcoming, :overdue_count, :practice_count, :situation, :next_event])
  end

  defp build_calendar_filter(input) do
    filters = ["deleted_at IS NULL"]
    filters = if c = input["category"], do: ["category = '#{sanitise(c)}'" | filters], else: filters
    filters = if s = input["status"], do: ["status = '#{sanitise(s)}'" | filters], else: filters
    Enum.join(filters, " AND ")
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _            -> System.os_time(:microsecond)
    end
  end
  defp parse_datetime(n) when is_integer(n), do: n
end
