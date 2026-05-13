# elixir/lib/przma/pzdb/health_monitor.ex
#
# Fixed circuit breaker with a real storage probe.
#
# Bug in previous version: probe_storage checked File.stat(base_path).
# On S3-backed deployments (cloud_saas, byos), base_path is a local
# directory that always exists even when S3 is completely unreachable.
# The circuit opened then immediately closed on the probe — no protection.
#
# Fix: probe actually reads the manifest of a known small lance table.
# If S3 is down, the NIF call fails → probe returns :error → circuit stays open.

defmodule PRZMA.PzDb.HealthMonitor do
  use GenServer
  require Logger

  @error_threshold     5
  @error_window_secs  60
  @probe_interval_ms  10_000
  @recovery_probes     3
  @latency_warn_us    500_000    # 500ms
  @latency_crit_us   2_000_000   # 2s — trip circuit if p99 exceeds this

  @base_path Application.compile_env(:przma, [:vault, :base_path], "/var/przma/vaults")

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check do
    case :ets.lookup(:pzdb_health, :circuit) do
      [{:circuit, :open}]     -> {:error, :circuit_open}
      [{:circuit, :half_open}] -> :ok   # Allow limited traffic through
      _                        -> :ok
    end
  end

  def record_success(latency_us) when is_integer(latency_us) do
    GenServer.cast(__MODULE__, {:success, latency_us})
  end

  def record_error(reason) do
    GenServer.cast(__MODULE__, {:error, reason})
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(:pzdb_health, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(:pzdb_health, {:circuit, :closed})

    {:ok, %{
      circuit:            :closed,
      error_count:        0,
      error_window_start: now_secs(),
      recovery_probes:    0,
      latency_samples:    :queue.new(),  # bounded ring of last 100 latencies
      sample_count:       0,
      total_writes:       0,
      total_errors:       0,
    }}
  end

  @impl true
  def handle_cast({:success, latency_us}, state) do
    state = add_latency_sample(state, latency_us)
    state = %{state | total_writes: state.total_writes + 1}

    p99 = latency_percentile(state, 99)

    state = cond do
      p99 >= @latency_crit_us ->
        Logger.error("Storage p99 latency critical — opening circuit",
          p99_ms: div(p99, 1000))
        open_circuit(state, :latency_critical)

      p99 >= @latency_warn_us ->
        Logger.warning("Storage p99 latency elevated",
          p99_ms: div(p99, 1000))
        emit(:high_latency, %{p99_us: p99})
        state

      true -> state
    end

    # Recovery path from half_open
    state = if state.circuit == :half_open do
      probes = state.recovery_probes + 1
      if probes >= @recovery_probes do
        Logger.info("Storage circuit closing — recovery confirmed")
        emit(:circuit_closed, %{})
        close_circuit(%{state | recovery_probes: 0, error_count: 0})
      else
        %{state | recovery_probes: probes}
      end
    else
      state
    end

    {:noreply, state}
  end

  def handle_cast({:error, reason}, state) do
    state = %{state | total_errors: state.total_errors + 1}
    n     = now_secs()

    # Reset window if expired
    state = if n - state.error_window_start > @error_window_secs do
      %{state | error_count: 0, error_window_start: n}
    else
      state
    end

    state = %{state | error_count: state.error_count + 1}

    Logger.warning("Storage write error",
      reason: inspect(reason),
      errors_in_window: state.error_count,
      threshold: @error_threshold)

    state = if state.error_count >= @error_threshold and state.circuit == :closed do
      open_circuit(state, reason)
    else
      state
    end

    {:noreply, state}
  end

  def handle_cast(:reset, state) do
    {:noreply, close_circuit(%{state | error_count: 0, recovery_probes: 0})}
  end

  @impl true
  def handle_call(:status, _from, state) do
    p99 = latency_percentile(state, 99)
    status = %{
      circuit:        state.circuit,
      error_count:    state.error_count,
      error_rate:     if(state.total_writes > 0, do: state.total_errors / state.total_writes, else: 0.0),
      p99_latency_ms: div(p99, 1000),
      total_writes:   state.total_writes,
      total_errors:   state.total_errors,
      recovery_probes: state.recovery_probes,
    }
    {:reply, status, state}
  end

  @impl true
  def handle_info(:probe, state) do
    case probe_storage() do
      :ok ->
        Logger.info("Storage probe succeeded — entering half_open")
        emit(:circuit_half_open, %{})
        state = %{state | circuit: :half_open, recovery_probes: 0}
        :ets.insert(:pzdb_health, {:circuit, :half_open})
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Storage probe failed — staying open", reason: inspect(reason))
        Process.send_after(self(), :probe, @probe_interval_ms)
        {:noreply, state}
    end
  end

  # ── FIXED: Real storage probe ──────────────────────────────────────────────
  # Old version: File.stat(base_path) — always succeeds even when S3 is down.
  # New version: actual Lance NIF call to read a version number.
  # This verifies the full path: Elixir → Rust NIF → S3/disk → manifest read.

  defp probe_storage do
    # Use a system metadata table that always exists
    # The probe Lance file is provisioned at application startup
    probe_table = "#{@base_path}/.przma-system/health-probe"
    start       = System.monotonic_time(:microsecond)

    result = try do
      case PRZMA.Calendar.NIF.pzdb_version(@base_path, probe_table) do
        {:ok, _version} -> :ok
        {:error, msg}   ->
          if String.contains?(msg, "not found") do
            :ok  # Table doesn't exist yet — that's fine, probe path works
          else
            {:error, msg}
          end
      end
    rescue
      e -> {:error, Exception.message(e)}
    end

    latency_us = System.monotonic_time(:microsecond) - start

    case result do
      :ok ->
        Logger.debug("Storage probe ok", latency_us: latency_us)
        :ok
      {:error, reason} ->
        Logger.warning("Storage probe failed", reason: reason, latency_us: latency_us)
        {:error, reason}
    end
  end

  # ── CIRCUIT STATE ─────────────────────────────────────────────────────────

  defp open_circuit(state, reason) do
    Logger.error("Storage circuit OPEN",
      reason: inspect(reason), error_count: state.error_count)
    emit(:circuit_open, %{reason: inspect(reason)})
    Process.send_after(self(), :probe, @probe_interval_ms)
    :ets.insert(:pzdb_health, {:circuit, :open})
    %{state |
      circuit:            :open,
      error_count:        0,
      error_window_start: now_secs(),
    }
  end

  defp close_circuit(state) do
    :ets.insert(:pzdb_health, {:circuit, :closed})
    %{state | circuit: :closed}
  end

  # ── LATENCY TRACKING ──────────────────────────────────────────────────────

  @max_samples 100

  defp add_latency_sample(state, latency_us) do
    q = :queue.in(latency_us, state.latency_samples)
    q = if :queue.len(q) > @max_samples, do: :queue.drop(q), else: q
    %{state | latency_samples: q, sample_count: state.sample_count + 1}
  end

  defp latency_percentile(state, p) do
    samples = :queue.to_list(state.latency_samples)
    case samples do
      [] -> 0
      _  ->
        sorted = Enum.sort(samples)
        idx    = max(0, ceil(length(sorted) * p / 100) - 1)
        Enum.at(sorted, idx, 0)
    end
  end

  defp now_secs, do: System.os_time(:second)

  defp emit(event, measurements) do
    :telemetry.execute([:pzdb, :health, event], measurements, %{})
  end
end
