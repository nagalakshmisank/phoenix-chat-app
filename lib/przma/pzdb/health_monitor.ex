# lib/przma/pzdb/health_monitor.ex
#
# Storage health monitor and circuit breaker.
#
# Circuit states:
#   :closed    -- normal operation
#   :open      -- storage unavailable, writes return {:error, :storage_unavailable}
#   :half_open -- testing recovery with limited traffic

defmodule PRZMA.PzDb.HealthMonitor do
  use GenServer
  require Logger

  @error_threshold     5        # errors before opening circuit
  @error_window_secs  60        # window for counting errors
  @probe_interval_ms 10_000     # probe interval in :half_open state
  @recovery_probes     3        # successful probes before closing circuit
  @latency_p99_warn_ms 500
  @latency_p99_crit_ms 2_000

  # ---- PUBLIC API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if storage is healthy. Returns :ok | {:error, :circuit_open}"
  def check do
    GenServer.call(__MODULE__, :check)
  end

  @doc "Record a successful write"
  def record_success(latency_us) do
    GenServer.cast(__MODULE__, {:success, latency_us})
  end

  @doc "Record a write error (may trip circuit)"
  def record_error(reason) do
    GenServer.cast(__MODULE__, {:error, reason})
  end

  @doc "Current health status"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Reset circuit to :closed -- call in test setup to avoid bleed between tests"
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # ---- GENSERVER ------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, fresh_state()}
  end

  @impl true
  def handle_call(:check, _from, %{circuit: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end
  def handle_call(:check, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    info = %{
      circuit:      state.circuit,
      error_count:  state.error_count,
      total_writes: state.total_writes,
      total_errors: state.total_errors,
      error_rate:   error_rate(state),
      p99_latency_ms: percentile(state.latency_samples, 99) |> div(1000),
    }
    {:reply, info, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, fresh_state()}
  end

  @impl true
  def handle_cast({:success, latency_us}, state) do
    samples = Enum.take([latency_us | state.latency_samples], 100)
    state   = %{state |
      total_writes:    state.total_writes + 1,
      latency_samples: samples,
      error_count:     0,
    }
    state = if state.circuit == :half_open do
      probes = state.recovery_probes + 1
      if probes >= @recovery_probes do
        Logger.info("Storage circuit CLOSED after recovery")
        %{state | circuit: :closed, recovery_probes: 0}
      else
        %{state | recovery_probes: probes}
      end
    else
      state
    end

    p99_ms = percentile(samples, 99) |> div(1000)
    cond do
      p99_ms >= @latency_p99_crit_ms ->
        Logger.error("pzdb p99 latency critical", p99_ms: p99_ms)
      p99_ms >= @latency_p99_warn_ms ->
        Logger.warning("pzdb p99 latency elevated", p99_ms: p99_ms)
      true -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:error, reason}, state) do
    now = System.os_time(:second)
    state = if now - state.error_window_start > @error_window_secs do
      %{state | error_count: 0, error_window_start: now}
    else
      state
    end

    state = %{state | error_count: state.error_count + 1, total_errors: state.total_errors + 1}

    Logger.warning("Storage write error",
      reason: inspect(reason),
      error_count: state.error_count,
      threshold: @error_threshold)

    state = if state.error_count >= @error_threshold and state.circuit == :closed do
      trip_circuit(state, reason)
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:probe, state) do
    case probe_storage() do
      :ok ->
        Logger.info("Storage probe succeeded -- entering half_open")
        {:noreply, %{state | circuit: :half_open, recovery_probes: 0}}
      {:error, _} ->
        Logger.warning("Storage probe failed -- staying open")
        Process.send_after(self(), :probe, @probe_interval_ms)
        {:noreply, state}
    end
  end

  # ---- PRIVATE --------------------------------------------------------------

  defp fresh_state do
    %{
      circuit:             :closed,
      error_count:         0,
      error_window_start:  System.os_time(:second),
      recovery_probes:     0,
      latency_samples:     [],
      total_writes:        0,
      total_errors:        0,
    }
  end

  defp trip_circuit(state, reason) do
    Logger.error("Storage circuit OPEN",
      reason: inspect(reason), error_count: state.error_count)
    :telemetry.execute([:pzdb, :circuit, :open], %{count: 1}, %{reason: reason})
    Process.send_after(self(), :probe, @probe_interval_ms)
    %{state | circuit: :open, error_count: 0, error_window_start: System.os_time(:second)}
  end

  defp probe_storage do
    base_path = Application.get_env(:pzdb, :vault, [])
                |> Keyword.get(:base_path, "/tmp/przma_vaults")
    case File.stat(base_path) do
      {:ok, %{type: :directory}} -> :ok
      _                          ->
        case File.mkdir_p(base_path) do
          :ok -> :ok
          err -> err
        end
    end
  end

  defp error_rate(%{total_writes: 0}), do: 0.0
  defp error_rate(%{total_writes: w, total_errors: e}), do: e / w

  defp percentile([], _), do: 0
  defp percentile(samples, p) do
    sorted = Enum.sort(samples)
    idx    = ceil(length(sorted) * p / 100) - 1
    Enum.at(sorted, max(0, idx), 0)
  end
end
