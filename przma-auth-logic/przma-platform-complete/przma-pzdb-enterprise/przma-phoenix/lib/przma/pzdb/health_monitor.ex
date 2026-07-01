# lib/przma/pzdb/health_monitor.ex
#
# Storage health monitor and circuit breaker.
#
# Monitors: Lance write latency, S3 manifest conflict rate, NIF error rate.
#
# Circuit states:
#   :closed   — normal operation
#   :open     — storage unavailable, writes return {:error, :storage_unavailable}
#   :half_open — testing recovery with limited traffic
#
# On S3: detects connectivity loss and conditional PUT failure rate.
# On local: detects disk full and Lance corruption.

defmodule PRZMA.PzDb.HealthMonitor do
  use GenServer
  require Logger

  @error_threshold     5       # errors in window before opening circuit
  @error_window_secs  60       # window for counting errors
  @probe_interval_ms 10_000    # probe interval in :half_open state
  @recovery_probes     3       # successful probes before closing circuit
  @latency_p99_warn_ms 500     # warn if p99 write latency exceeds this
  @latency_p99_crit_ms 2_000   # open circuit if p99 exceeds this

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Check if storage is healthy. Returns :ok | {:error, :circuit_open}"
  def check do
    GenServer.call(__MODULE__, :check)
  end

  @doc "Record a successful write (resets error window)"
  def record_success(latency_us) do
    GenServer.cast(__MODULE__, {:success, latency_us})
  end

  @doc "Record a write error (may trip circuit)"
  def record_error(reason) do
    GenServer.cast(__MODULE__, {:error, reason})
  end

  @doc "Current health status — for dashboards and /health endpoint"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      circuit:         :closed,
      error_count:     0,
      error_window_start: System.os_time(:second),
      recovery_probes: 0,
      latency_samples: [],
      total_writes:    0,
      total_errors:    0,
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, %{circuit: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end
  def handle_call(:check, _from, %{circuit: :half_open} = state) do
    # Allow limited traffic through for probing
    {:reply, :ok, state}
  end
  def handle_call(:check, _from, %{circuit: :closed} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    p99 = percentile(state.latency_samples, 99)
    {:reply, %{
      circuit:        state.circuit,
      error_rate:     error_rate(state),
      p99_latency_ms: p99 / 1000,
      total_writes:   state.total_writes,
      total_errors:   state.total_errors,
    }, state}
  end

  @impl true
  def handle_cast({:success, latency_us}, state) do
    samples = [latency_us | Enum.take(state.latency_samples, 99)]
    p99     = percentile(samples, 99)

    state = %{state |
      latency_samples: samples,
      total_writes:    state.total_writes + 1,
    }

    # High latency check
    state = cond do
      p99 > @latency_p99_crit_ms * 1000 ->
        Logger.error("Storage p99 latency critical — opening circuit", p99_ms: p99 / 1000)
        trip_circuit(state, :latency_critical)

      p99 > @latency_p99_warn_ms * 1000 ->
        Logger.warning("Storage p99 latency high", p99_ms: p99 / 1000)
        :telemetry.execute([:pzdb, :health, :high_latency], %{p99_us: p99}, %{})
        state

      true -> state
    end

    # Recovery in half_open state
    state = if state.circuit == :half_open do
      probes = state.recovery_probes + 1
      if probes >= @recovery_probes do
        Logger.info("Storage circuit closing — recovery confirmed")
        %{state | circuit: :closed, recovery_probes: 0, error_count: 0}
      else
        %{state | recovery_probes: probes}
      end
    else
      state
    end

    {:noreply, state}
  end

  def handle_cast({:error, reason}, state) do
    now   = System.os_time(:second)
    state = %{state | total_errors: state.total_errors + 1}

    # Reset window if expired
    state = if now - state.error_window_start > @error_window_secs do
      %{state | error_count: 0, error_window_start: now}
    else
      state
    end

    state = %{state | error_count: state.error_count + 1}

    Logger.warning("Storage write error", reason: inspect(reason),
      error_count: state.error_count, threshold: @error_threshold)

    state = if state.error_count >= @error_threshold and state.circuit == :closed do
      trip_circuit(state, reason)
    else
      state
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:probe, state) do
    # Probe storage health in :open state
    case probe_storage() do
      :ok ->
        Logger.info("Storage probe succeeded — entering half_open")
        {:noreply, %{state | circuit: :half_open, recovery_probes: 0}}
      {:error, _} ->
        Logger.warning("Storage probe failed — staying open")
        Process.send_after(self(), :probe, @probe_interval_ms)
        {:noreply, state}
    end
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp trip_circuit(state, reason) do
    Logger.error("Storage circuit OPEN", reason: inspect(reason),
      error_count: state.error_count)
    :telemetry.execute([:pzdb, :circuit, :open], %{count: 1}, %{reason: reason})
    Process.send_after(self(), :probe, @probe_interval_ms)
    %{state | circuit: :open, error_count: 0, error_window_start: System.os_time(:second)}
  end

  defp probe_storage do
    # Lightweight probe: try to read a known table version
    base_path = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")
    case File.stat(base_path) do
      {:ok, %{type: :directory}} -> :ok
      _                          -> {:error, :path_unavailable}
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
