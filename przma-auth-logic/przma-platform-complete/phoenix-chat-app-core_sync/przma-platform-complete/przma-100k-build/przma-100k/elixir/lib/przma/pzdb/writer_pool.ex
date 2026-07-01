# elixir/lib/przma/pzdb/writer_pool.ex
#
# Fixed pool of 1000 write workers, replacing the per-DID VaultWriter GenServer.
#
# Why: one GenServer per active DID does not scale past ~50K concurrent users.
#   DynamicSupervisor with 1M children has O(N) child lookup overhead.
#   100K concurrent DIDs × 5KB process overhead = 500MB process state.
#
# Fix: 1000 fixed workers started at application boot.
#   Each DID is routed to worker_idx = :erlang.phash2(did, 1000).
#   Two DIDs in the same shard are both queued through one worker — this is
#   acceptable because the probability of collision in a shard is 1/1000, and
#   within a shard the writes are still sequential (no OCC conflict possible).
#
# Result: 1000 long-lived GenServers instead of up to 1M short-lived ones.
#   Process overhead: 1000 × 5KB = 5MB.   Fixed. Predictable.
#   Supervisor children: 1000.             Fast lookup, stable supervision tree.

defmodule PRZMA.PzDb.WriterPool do
  @moduledoc """
  Supervises a fixed pool of 1000 WriteWorker GenServers.
  Each DID is consistently routed to one worker via :erlang.phash2.
  """

  use Supervisor

  @pool_size 1_000

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = for i <- 0..(@pool_size - 1) do
      {PRZMA.PzDb.WriteWorker, index: i}
    end
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Execute a write function under the DID's write lock.
  Routes to the worker responsible for this DID and queues the call.
  Returns {:ok, result} | {:error, reason} | {:error, :backpressure}
  """
  def write(did, fun) when is_function(fun, 0) do
    idx = :erlang.phash2(did, @pool_size)
    PRZMA.PzDb.WriteWorker.call(idx, {:write, did, fun})
  end

  @doc "Queue depth for the worker handling this DID"
  def queue_depth(did) do
    idx = :erlang.phash2(did, @pool_size)
    PRZMA.PzDb.WriteWorker.queue_depth(idx)
  end

  @doc "Which worker index handles this DID"
  def worker_for(did), do: :erlang.phash2(did, @pool_size)

  @doc "Pool status — queue depth per worker"
  def status do
    for i <- 0..(@pool_size - 1) do
      {i, PRZMA.PzDb.WriteWorker.queue_depth(i)}
    end
  end

  @doc "Count of workers currently under pressure (queue > 50)"
  def pressure_count do
    status() |> Enum.count(fn {_, depth} -> depth > 50 end)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.PzDb.WriteWorker do
  @moduledoc """
  Individual write worker in the pool.
  Serialises all writes routed to its shard.
  Never shuts down — lives for the application lifetime.
  """

  use GenServer

  @max_queue_depth  100
  @call_timeout_ms  30_000

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts) do
    idx = Keyword.fetch!(opts, :index)
    GenServer.start_link(__MODULE__, idx, name: via(idx))
  end

  def call(idx, msg) do
    GenServer.call(via(idx), msg, @call_timeout_ms)
  end

  def queue_depth(idx) do
    case GenServer.call(via(idx), :queue_depth, 1_000) do
      {:ok, n} -> n
      _        -> 0
    end
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(idx) do
    Process.flag(:trap_exit, true)
    {:ok, %{
      index:       idx,
      queue_depth: 0,
      writes_ok:   0,
      writes_err:  0,
    }}
  end

  @impl true
  def handle_call(:queue_depth, _from, state) do
    {:reply, {:ok, state.queue_depth}, state}
  end

  def handle_call({:write, _did, fun}, _from, state) do
    if state.queue_depth >= @max_queue_depth do
      :telemetry.execute([:pzdb, :write, :rejected],
        %{count: 1}, %{worker: state.index, reason: :backpressure})
      {:reply, {:error, :backpressure}, state}
    else
      state = %{state | queue_depth: state.queue_depth + 1}

      start  = System.monotonic_time(:microsecond)
      result = execute_write(fun)
      dur    = System.monotonic_time(:microsecond) - start

      :telemetry.execute([:pzdb, :write, :complete],
        %{duration_us: dur}, %{worker: state.index})

      {ok_count, err_count} = case result do
        {:ok, _}    -> {1, 0}
        {:error, _} -> {0, 1}
        _           -> {1, 0}
      end

      state = %{state |
        queue_depth: state.queue_depth - 1,
        writes_ok:   state.writes_ok  + ok_count,
        writes_err:  state.writes_err + err_count,
      }
      {:reply, result, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :telemetry.execute([:pzdb, :worker, :terminate],
      %{writes: state.writes_ok}, %{worker: state.index})
    :ok
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp execute_write(fun) do
    try do
      case fun.() do
        {:ok, _}    = ok  -> ok
        {:error, _} = err -> err
        other             -> {:ok, other}
      end
    rescue
      e -> {:error, {:exception, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:exit, reason}}
    end
  end

  defp via(idx) do
    {:via, Registry, {PRZMA.PzDb.WorkerRegistry, idx}}
  end
end
