# lib/przma/pzdb/supervisor.ex
#
# Supervision tree for the PzDb layer.
# Add PRZMA.PzDb.Supervisor to your application.ex children list.

defmodule PRZMA.PzDb.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Registry for VaultWriter GenServers — one entry per active DID
      {Registry, keys: :unique, name: PRZMA.PzDb.WriterRegistry},

      # DynamicSupervisor for VaultWriter instances
      {DynamicSupervisor, name: PRZMA.PzDb.WriterSupervisor, strategy: :one_for_one},

      # ETS-backed read cache
      PRZMA.PzDb.ReadCache,

      # Compaction scheduler
      PRZMA.PzDb.Compaction,

      # Health monitor and circuit breaker
      PRZMA.PzDb.HealthMonitor,

      # Telemetry handler
      {PRZMA.PzDb.Telemetry, []},

      # Notification subsystem (inbox / outbox / notifications + S3 health)
      PRZMA.PzDb.Notification.Supervisor,
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.PzDb.Telemetry do
  @moduledoc """
  Attaches telemetry handlers for PzDb operations.
  Reports to: Logger (always), StatsD/Prometheus (if configured).
  """

  use GenServer
  require Logger

  @events [
    [:pzdb, :write, :ok],
    [:pzdb, :write, :error],
    [:pzdb, :write, :rejected],
    [:pzdb, :write, :complete],
    [:pzdb, :read, :ok],
    [:pzdb, :read, :cache_hit],
    [:pzdb, :cache, :put],
    [:pzdb, :circuit, :open],
    [:pzdb, :health, :high_latency],
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :telemetry.attach_many(
      "pzdb-telemetry",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
    {:ok, %{}}
  end

  def handle_event([:pzdb, :write, :ok], measurements, meta, _) do
    if measurements.attempts > 1 do
      Logger.debug("pzdb write succeeded after retries",
        uri:      meta.uri,
        attempts: measurements.attempts,
        latency_ms: measurements.latency_us / 1000)
    end
    # Emit to metrics backend
    emit_metric("pzdb.write.latency_us", measurements.latency_us, meta)
    emit_metric("pzdb.write.attempts",   measurements.attempts,   meta)
  end

  def handle_event([:pzdb, :write, :error], _measurements, meta, _) do
    Logger.warning("pzdb write failed", uri: meta.uri)
    emit_metric("pzdb.write.errors", 1, meta)
  end

  def handle_event([:pzdb, :write, :rejected], _measurements, meta, _) do
    Logger.warning("pzdb write rejected (backpressure)", did: meta.did)
    emit_metric("pzdb.write.rejected", 1, meta)
  end

  def handle_event([:pzdb, :read, :cache_hit], _measurements, meta, _) do
    emit_metric("pzdb.cache.hits", 1, meta)
  end

  def handle_event([:pzdb, :circuit, :open], _measurements, meta, _) do
    Logger.error("pzdb circuit breaker OPEN", reason: meta.reason)
    emit_metric("pzdb.circuit.open", 1, meta)
  end

  def handle_event([:pzdb, :health, :high_latency], measurements, _meta, _) do
    Logger.warning("pzdb storage latency high", p99_us: measurements.p99_us)
  end

  def handle_event(_event, _measurements, _meta, _), do: :ok

  defp emit_metric(_name, _value, _meta) do
    # Hook into your metrics backend here:
    # Statix.increment(name, tags: ["uri:#{meta[:uri]}"])
    # PromEx.record(name, value, meta)
    :ok
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.PzDb.Uri do
  @moduledoc "Thin Elixir parser for pzdb:// URIs"

  def parse("pzdb://" <> body) do
    case String.split(body, "/", parts: 5) do
      [did, service, space, table, record_id]
          when did != "" and service != "" and table != "" ->
        {:ok, %{did: did, service: service, space: space,
                table: table, record_id: record_id}}
      _ ->
        {:error, :invalid_pzdb_uri}
    end
  end
  def parse(other), do: {:error, {:not_pzdb, other}}

  def lance_path(base_path, %{did: did, service: service, space: space, table: table}) do
    Path.join([base_path, did, service, space, table])
  end

  def to_string(%{did: did, service: s, space: sp, table: t, record_id: id}) do
    "pzdb://#{did}/#{s}/#{sp}/#{t}/#{id}"
  end
end
