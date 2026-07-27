# lib/przma/pzdb/vault_writer.ex
#
# Per-DID write serialiser.
#
# Guarantees:
#   - All writes for a DID are sequential — no OCC conflicts from this node
#   - Readers bypass entirely — no read latency impact
#   - Backpressure: rejects writes when queue exceeds @max_queue_depth
#   - Telemetry: emits write duration, queue depth, retry counts
#   - Auto-shutdown: GenServer exits after @idle_timeout_ms of inactivity
#
# One GenServer per active DID. Started on first write, stopped after idle.
# Registry: PRZMA.PzDbV2.WriterRegistry (local ETS-based)

defmodule PRZMA.PzDbV2.VaultWriter do
  use GenServer, restart: :temporary

  require Logger

  @max_queue_depth   100     # reject writes beyond this depth
  @idle_timeout_ms  60_000   # shut down after 60s with no writes
  @call_timeout_ms  30_000   # max wait for a write to complete

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(did) do
    GenServer.start_link(__MODULE__, did, name: via(did))
  end

  @doc """
  Execute a write function under the DID's serialization lock.
  The function must return {:ok, result} | {:error, reason}.

  Raises PRZMA.PzDb.BackpressureError if the write queue is full.
  """
  def write(did, fun) when is_function(fun, 0) do
    ensure_started(did)

    case GenServer.call(via(did), :queue_depth, 1_000) do
      depth when depth >= @max_queue_depth ->
        :telemetry.execute([:pzdb, :write, :rejected],
          %{count: 1}, %{did: did, reason: :backpressure})
        {:error, :backpressure}

      _ ->
        start = System.monotonic_time(:microsecond)
        result = GenServer.call(via(did), {:write, fun}, @call_timeout_ms)
        duration = System.monotonic_time(:microsecond) - start

        :telemetry.execute([:pzdb, :write, :complete],
          %{duration_us: duration}, %{did: did})

        result
    end
  end

  @doc "Current queue depth for a DID (0 if writer not running)"
  def queue_depth(did) do
    case Registry.lookup(PRZMA.PzDbV2.WriterRegistry, did) do
      [{pid, _}] -> GenServer.call(pid, :queue_depth, 1_000)
      []         -> 0
    end
  end

  @doc "Force-stop the writer for a DID (used in tests)"
  def stop(did) do
    case Registry.lookup(PRZMA.PzDbV2.WriterRegistry, did) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      []         -> :ok
    end
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(did) do
    state = %{
      did:         did,
      queue_depth: 0,
      write_count: 0,
      error_count: 0,
    }
    {:ok, state, @idle_timeout_ms}
  end

  @impl true
  def handle_call(:queue_depth, _from, state) do
    {:reply, state.queue_depth, state, @idle_timeout_ms}
  end

  def handle_call({:write, fun}, _from, state) do
    state = %{state | queue_depth: state.queue_depth + 1}

    {result, new_state} =
      try do
        r = fun.()
        {r, %{state | write_count: state.write_count + 1}}
      rescue
        e ->
          Logger.error("VaultWriter: write function raised",
            did: state.did, error: inspect(e))
          {{:error, {:exception, inspect(e)}},
           %{state | error_count: state.error_count + 1}}
      end

    final_state = %{new_state | queue_depth: new_state.queue_depth - 1}
    {:reply, result, final_state, @idle_timeout_ms}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("VaultWriter idle shutdown", did: state.did,
      writes: state.write_count, errors: state.error_count)
    {:stop, :normal, state}
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp via(did) do
    {:via, Registry, {PRZMA.PzDbV2.WriterRegistry, did}}
  end

  defp ensure_started(did) do
    case Registry.lookup(PRZMA.PzDbV2.WriterRegistry, did) do
      [{_pid, _}] -> :ok
      []          ->
        case DynamicSupervisor.start_child(
               PRZMA.PzDbV2.WriterSupervisor,
               {__MODULE__, did}
             ) do
          {:ok, _pid}                   -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason}              ->
            Logger.error("Failed to start VaultWriter", did: did, reason: inspect(reason))
            {:error, reason}
        end
    end
  end
end
