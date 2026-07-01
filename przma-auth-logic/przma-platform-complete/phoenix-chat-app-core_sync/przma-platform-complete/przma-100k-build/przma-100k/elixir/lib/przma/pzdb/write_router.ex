# elixir/lib/przma/pzdb/write_router.ex
#
# Consistent-hash ring write router for distributed PRZMA nodes.
#
# Problem with the old approach: :erlang.phash2(did, cluster_size)
#   When cluster grows from 10 → 11 nodes, ALL DIDs remap simultaneously.
#   This causes a thundering herd of new S3 connections and VaultWriter restarts.
#
# This implementation uses a consistent hash ring with 150 virtual nodes per
# physical node. When a node is added or removed, only ~1/N DIDs remap
# instead of all of them. This is the standard algorithm used by Cassandra,
# DynamoDB, and Riak.
#
# Virtual nodes: each physical node is placed at 150 positions on the ring.
# This distributes load evenly and reduces the "hole" when a node fails.
#
# Ring storage: ETS table :przma_hash_ring, rebuilt on cluster membership changes.
# Ring format: sorted list of {hash_value, node} tuples.

defmodule PRZMA.PzDb.WriteRouter do
  use GenServer
  require Logger

  @ring_table      :przma_hash_ring
  @virtual_nodes   150    # virtual nodes per physical node
  @rpc_timeout_ms  30_000

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Execute a write for a DID on the correct cluster node.
  In single-node mode: always local.
  In cluster mode: routes to the DID's home node, falls back on node failure.
  """
  def write(did, fun) when is_function(fun, 0) do
    target = home_node(did)
    if target == Node.self() do
      PRZMA.PzDb.WriterPool.write(did, fun)
    else
      route_remote(target, did, fun)
    end
  end

  @doc "Which node owns writes for this DID?"
  def home_node(did) do
    case :ets.lookup(@ring_table, :ring) do
      [{:ring, ring}] -> ring_lookup(ring, did)
      []              -> Node.self()
    end
  end

  @doc "All nodes in the current cluster, sorted for ring stability"
  def cluster_nodes, do: [Node.self() | Node.list()] |> Enum.sort()

  @doc "Force ring rebuild (called when :nodeup/:nodedown received)"
  def rebuild_ring, do: GenServer.cast(__MODULE__, :rebuild)

  @doc "Cluster topology for monitoring"
  def topology do
    nodes = cluster_nodes()
    %{
      nodes:        nodes,
      node_count:   length(nodes),
      ring_size:    @virtual_nodes * length(nodes),
      my_node:      Node.self(),
    }
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@ring_table, [:set, :public, :named_table, read_concurrency: true])
    build_ring()

    # Subscribe to node up/down events
    :net_kernel.monitor_nodes(true)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:rebuild, state) do
    build_ring()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node joined cluster — rebuilding ring", node: node)
    build_ring()
    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node left cluster — rebuilding ring", node: node)
    build_ring()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── RING IMPLEMENTATION ───────────────────────────────────────────────────

  defp build_ring do
    nodes = cluster_nodes()
    ring  = build_ring_for(nodes)
    :ets.insert(@ring_table, {:ring, ring})
    Logger.debug("Hash ring rebuilt",
      nodes: length(nodes),
      virtual_nodes: length(ring))
  end

  @doc false
  def build_ring_for(nodes) do
    nodes
    |> Enum.flat_map(fn node ->
        Enum.map(1..@virtual_nodes, fn i ->
          hash = hash_key({node, i})
          {hash, node}
        end)
      end)
    |> Enum.sort_by(fn {hash, _} -> hash end)
  end

  defp ring_lookup([], _did), do: Node.self()
  defp ring_lookup(ring, did) do
    hash = hash_key(did)
    # Find the first node with hash >= did's hash
    case Enum.find(ring, fn {h, _} -> h >= hash end) do
      {_, node} -> node
      nil       -> ring |> List.first() |> elem(1)  # Wrap around ring
    end
  end

  defp hash_key(key) do
    # Use phash2 on a tuple for uniform distribution
    :erlang.phash2(key, 0xFFFFFFFF)
  end

  # ── REMOTE ROUTING ────────────────────────────────────────────────────────

  defp route_remote(target_node, did, fun) do
    case :rpc.call(target_node, PRZMA.PzDb.WriterPool, :write, [did, fun], @rpc_timeout_ms) do
      {:badrpc, :nodedown} ->
        Logger.warning("Write router: node down, failing over",
          target: target_node, did: String.slice(did, 0, 30))
        fallback_write(did, fun, exclude: target_node)

      {:badrpc, reason} ->
        Logger.error("Write router: RPC failed",
          node: target_node, reason: inspect(reason))
        {:error, {:rpc_failed, reason}}

      result ->
        result
    end
  end

  defp fallback_write(did, fun, exclude: bad_node) do
    # Rebuild ring without the failed node and route again
    available = cluster_nodes() -- [bad_node]
    fallback_ring = build_ring_for(available)
    fallback_node = ring_lookup(fallback_ring, did)

    if fallback_node == Node.self() do
      PRZMA.PzDb.WriterPool.write(did, fun)
    else
      case :rpc.call(fallback_node, PRZMA.PzDb.WriterPool, :write, [did, fun], @rpc_timeout_ms) do
        {:badrpc, reason} -> {:error, {:all_nodes_failed, reason}}
        result            -> result
      end
    end
  end
end
