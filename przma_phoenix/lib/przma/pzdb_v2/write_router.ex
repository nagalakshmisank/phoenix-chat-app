# lib/przma/pzdb/write_router.ex
#
# Distributed write router using consistent hashing.
#
# Routes each DID's writes to a specific Phoenix node.
# The hash is stable: same DID → same node, even as cluster membership changes.
# On node failure: fails over to the next node in the ring.
#
# Reads: always local — any node can read any Lance table.
# Writes: routed to the DID's home node — avoids cross-node OCC conflicts.

defmodule PRZMA.PzDbV2.WriteRouter do
  require Logger

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  @doc """
  Execute a write function for a DID, routing to the correct cluster node.

  In single-node mode: runs locally.
  In cluster mode: routes via :rpc.call to the DID's home node.
  If the home node is unavailable: falls back to the next node in the ring.
  """
  def write(did, fun) when is_function(fun, 0) do
    target = home_node(did)

    if target == Node.self() do
      PRZMA.PzDbV2.VaultWriter.write(did, fun)
    else
      route_to_node(target, did, fun)
    end
  end

  @doc "Which node is responsible for writes for this DID?"
  def home_node(did) do
    nodes = cluster_nodes()
    case nodes do
      []      -> Node.self()
      [_] = n -> hd(n)
      nodes   -> Enum.at(nodes, consistent_hash(did, length(nodes)))
    end
  end

  @doc "All nodes currently in the cluster (self + connected)"
  def cluster_nodes do
    [Node.self() | Node.list()] |> Enum.sort()
  end

  @doc "Cluster health summary — for monitoring"
  def cluster_status do
    nodes    = cluster_nodes()
    statuses = Enum.map(nodes, fn node ->
      alive = node == Node.self() or Node.ping(node) == :pong
      %{node: node, alive: alive, is_self: node == Node.self()}
    end)
    %{
      node_count: length(nodes),
      nodes:      statuses,
      healthy:    Enum.all?(statuses, & &1.alive),
    }
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp route_to_node(target_node, did, fun) do
    case :rpc.call(target_node, PRZMA.PzDbV2.VaultWriter, :write, [did, fun], 30_000) do
      {:badrpc, :nodedown} ->
        Logger.warning("Write router: home node down, failing over",
          target: target_node, did: did)
        # Fail over to the next node in the ring
        fallback = fallback_node(did, target_node)
        if fallback == Node.self() do
          PRZMA.PzDbV2.VaultWriter.write(did, fun)
        else
          :rpc.call(fallback, PRZMA.PzDbV2.VaultWriter, :write, [did, fun], 30_000)
          |> unwrap_rpc()
        end

      {:badrpc, reason} ->
        Logger.error("Write router: RPC failed", node: target_node, reason: inspect(reason))
        {:error, {:rpc_failed, reason}}

      result ->
        unwrap_rpc(result)
    end
  end

  defp fallback_node(did, excluded_node) do
    nodes = cluster_nodes() -- [excluded_node]
    case nodes do
      [] -> Node.self()
      _  -> Enum.at(nodes, consistent_hash(did, length(nodes)))
    end
  end

  # Consistent hashing: same DID always maps to the same bucket
  # Uses erlang:phash2 which is stable across nodes in the same OTP version
  defp consistent_hash(did, ring_size) do
    :erlang.phash2(did, ring_size)
  end

  defp unwrap_rpc({:badrpc, reason}), do: {:error, {:rpc_error, reason}}
  defp unwrap_rpc(result),            do: result
end
