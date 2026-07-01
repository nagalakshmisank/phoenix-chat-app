# lib/registry/agent_registry.ex
#
# ETS-backed registry of available agent types and their capabilities.
# Loaded at startup. Custom agents (sovereign tier) register at runtime.

defmodule PRZMA.Agents.Registry do
  use GenServer
  require Logger

  @table :przma_agent_registry

  # ── BUILT-IN AGENT DEFINITIONS ──────────────────────────────────────────────

  @built_in_agents [
    %{
      type:         :companion,
      name:         "PRZMA Companion",
      description:  "Primary perception intelligence companion. Reads all services, writes to vault.",
      min_tier:     :free_local,
      tools:        ~w(vault:read vault:write calendar:read companion:context metadata:read ai:infer),
      max_steps:    20,
      streaming:    true,
      singleton:    false,   # one per DID at most? No — allow multiple companion sessions
    },
    %{
      type:         :calendar,
      name:         "Calendar Agent",
      description:  "Creates, updates, and manages calendar events and tasks.",
      min_tier:     :essential,
      tools:        ~w(calendar:read calendar:write vault:read metadata:read),
      max_steps:    15,
      streaming:    false,
    },
    %{
      type:         :vault_scribe,
      name:         "Vault Scribe",
      description:  "Writes vault entries from voice, text, or chat input. Routes to correct domain.",
      min_tier:     :essential,
      tools:        ~w(vault:read vault:write calendar:read companion:context),
      max_steps:    10,
      streaming:    false,
    },
    %{
      type:         :file_organizer,
      name:         "File Organizer",
      description:  "Tags, categorises, and organises files. Creates metadata index entries.",
      min_tier:     :professional,
      tools:        ~w(files:read files:write metadata:read metadata:write vault:read),
      max_steps:    30,
      streaming:    false,
    },
    %{
      type:         :metadata_indexer,
      name:         "Metadata Indexer",
      description:  "Re-indexes search across all services for a DID. Runs in background.",
      min_tier:     :professional,
      tools:        ~w(vault:read calendar:read chat:read files:read metadata:write ai:infer),
      max_steps:    100,
      streaming:    false,
      background:   true,   # runs as Oban job, not interactive
    },
    %{
      type:         :analytics,
      name:         "Analytics Agent",
      description:  "Runs DuckDB analytics and summarises insights in plain language.",
      min_tier:     :professional,
      tools:        ~w(calendar:read vault:read metadata:read ai:infer),
      max_steps:    20,
      streaming:    true,
    },
    %{
      type:         :scanner,
      name:         "Scanner Agent",
      description:  "Runs the PRZMA 23-scanner framework to surface patterns and insights.",
      min_tier:     :professional,
      tools:        ~w(vault:read calendar:read companion:context ai:infer metadata:write),
      max_steps:    50,
      streaming:    true,
      background:   true,
    },
    %{
      type:         :jodhi_navigator,
      name:         "JODHI Resource Navigator",
      description:  "Community resource navigation agent for informal economy workers.",
      min_tier:     :essential,
      tools:        ~w(metadata:read web:search vault:write),
      max_steps:    15,
      streaming:    true,
    },
    %{
      type:         :meeting_scribe,
      name:         "Meeting Scribe",
      description:  "Transcribes, extracts action items, and writes post-meeting reflections.",
      min_tier:     :essential,
      tools:        ~w(calendar:read calendar:write vault:write ai:infer),
      max_steps:    15,
      streaming:    false,
    },
  ]

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get agent definition by type atom."
  def get(agent_type) when is_atom(agent_type) do
    case :ets.lookup(@table, agent_type) do
      [{_, agent}] -> {:ok, agent}
      []           -> {:error, :unknown_agent_type}
    end
  end

  @doc "List all registered agent types available for a DID's tier."
  def list(did_tier \\ :sovereign) do
    :ets.tab2list(@table)
    |> Enum.map(fn {_, agent} -> agent end)
    |> Enum.filter(fn agent -> tier_allows?(did_tier, agent.min_tier) end)
  end

  @doc "Check whether an agent type is available for this DID."
  def check_agent_available(did, agent_type) do
    tier = PRZMA.Deployment.License.did_tier(did)

    case get(agent_type) do
      {:ok, agent} ->
        if tier_allows?(tier, agent.min_tier) do
          :ok
        else
          {:error, {:tier_required, agent.min_tier, "Current tier: #{tier}"}}
        end
      {:error, _} ->
        {:error, {:unknown_agent_type, agent_type}}
    end
  end

  @doc "Register a custom agent type (sovereign tier feature)."
  def register_custom(did, definition) do
    tier = PRZMA.Deployment.License.did_tier(did)
    unless tier == :sovereign do
      {:error, :sovereign_tier_required}
    else
      agent = Map.merge(definition, %{
        type:     String.to_atom("custom_#{definition[:name] |> String.downcase() |> String.replace(~r/\W/, "_")}"),
        min_tier: :sovereign,
        custom:   true,
        owner:    did,
      })
      :ets.insert(@table, {agent.type, agent})
      Logger.info("Custom agent registered", did: did, type: agent.type)
      {:ok, agent}
    end
  end

  @doc "Maximum allowed active sessions for this tier."
  def max_sessions(tier) do
    case tier do
      :free_local   ->  1
      :essential    ->  2
      :professional ->  5
      :sovereign    ->  :unlimited
      _             ->  1
    end
  end

  @doc "Maximum tool calls per session for this tier."
  def max_steps(tier, agent_type) do
    base = case get(agent_type) do
      {:ok, agent} -> agent[:max_steps] || 20
      _            -> 20
    end
    case tier do
      :free_local   -> min(base, 5)
      :essential    -> min(base, 20)
      :professional -> min(base, 50)
      :sovereign    -> base
      _             -> 5
    end
  end

  # ── GENSERVER ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    Enum.each(@built_in_agents, fn agent ->
      :ets.insert(@table, {agent.type, agent})
    end)

    Logger.info("Agent registry initialised", agent_count: length(@built_in_agents))
    {:ok, %{}}
  end

  # ── HELPERS ───────────────────────────────────────────────────────────────

  @tier_order [:free_local, :essential, :professional, :sovereign]

  defp tier_allows?(user_tier, required_tier) do
    user_idx     = Enum.find_index(@tier_order, &(&1 == user_tier))    || 0
    required_idx = Enum.find_index(@tier_order, &(&1 == required_tier)) || 0
    user_idx >= required_idx
  end
end
