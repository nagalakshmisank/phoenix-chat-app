# lib/przma/pzdb/compaction.ex
#
# Automatic Lance table compaction.
#
# Two triggers:
#   1. Fragment threshold: compact when fragment count exceeds @fragment_threshold
#   2. Schedule: nightly at 03:00 UTC for all tables above @min_rows_to_compact
#
# Compaction is a write operation — it goes through VaultWriter to avoid
# conflicts with concurrent user writes.
#
# Compaction runs per-table, not per-vault, so tables that change infrequently
# (ai/model_registry, social/memberships) are compacted less often.

defmodule PRZMA.PzDbV2.Compaction do
  use GenServer
  require Logger

  @fragment_threshold  50      # compact if fragment count exceeds this
  @min_rows_to_compact  10    # don't compact tiny tables
  @check_interval_ms  300_000  # check every 5 minutes

  # Hot tables get checked for fragment threshold every @check_interval_ms
  @hot_tables [
    {"calendar", "core",      "events"},
    {"calendar", "core",      "tasks"},
    {"vault",    "core",      "entries"},
    {"companion","core",      "memories"},
    {"companion","core",      "arc_timeline"},
    {"chat",     "core",      "messages"},
    {"metadata", "core",      "search_index"},
  ]

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Manually trigger compaction for a specific table"
  def compact_now(did, service, space, table) do
    GenServer.cast(__MODULE__, {:compact_now, did, service, space, table})
  end

  @doc "Check and compact all hot tables for a DID if thresholds are met"
  def check_and_compact(did) do
    GenServer.cast(__MODULE__, {:check_did, did})
  end

  @doc "Compaction status report for monitoring"
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{
      compactions_run:     0,
      compactions_failed:  0,
      last_compact_at:     nil,
    }}
  end

  @impl true
  def handle_cast({:compact_now, did, service, space, table}, state) do
    state = run_compaction(did, service, space, table, state)
    {:noreply, state}
  end

  def handle_cast({:check_did, did}, state) do
    # Check hot tables for this DID
    state = Enum.reduce(@hot_tables, state, fn {service, space, table}, acc ->
      if needs_compaction?(did, service, space, table) do
        run_compaction(did, service, space, table, acc)
      else
        acc
      end
    end)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:check_all, state) do
    # This fires every 5 minutes — check fragment thresholds for all active DIDs
    active_dids = PRZMA.PzDbV2.VaultWriter.active_dids()
    state = Enum.reduce(active_dids, state, fn did, acc ->
      Enum.reduce(@hot_tables, acc, fn {service, space, table}, s ->
        if needs_compaction?(did, service, space, table) do
          run_compaction(did, service, space, table, s)
        else
          s
        end
      end)
    end)
    schedule_check()
    {:noreply, state}
  end

  def handle_info({:nightly_compact, did}, state) do
    Logger.info("Starting nightly compaction", did: did)
    state = Enum.reduce(@hot_tables, state, fn {service, space, table}, acc ->
      run_compaction(did, service, space, table, acc)
    end)
    {:noreply, state}
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp needs_compaction?(did, service, space, table) do
    base_path = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")
    table_path = "#{base_path}/#{did}/#{service}/#{space}/#{table}"

    case PRZMA.PzDb.NIF.pzdb_version(base_path, table_path) do
      {:ok, version_json} ->
        version = Jason.decode!(version_json)
        # Use version as a proxy for fragment count — high version = many writes = many fragments
        version > @fragment_threshold
      _ ->
        false
    end
  end

  defp run_compaction(did, service, space, table, state) do
    base_path  = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")
    table_path = "#{base_path}/#{did}/#{service}/#{space}/#{table}"

    Logger.info("Running Lance compaction",
      did: did, service: service, space: space, table: table)

    # Compaction goes through VaultWriter — serialised with user writes
    result = PRZMA.PzDbV2.VaultWriter.write(did, fn ->
      case PRZMA.PzDb.NIF.pzdb_compact(base_path, table_path) do
        {:ok, stats_json} ->
          stats = Jason.decode!(stats_json)
          Logger.info("Compaction complete",
            did: did, table: table,
            rows: stats["rows_compacted"],
            duration_ms: stats["duration_ms"])
          {:ok, stats}
        {:error, msg} ->
          {:error, msg}
      end
    end)

    case result do
      {:ok, _} ->
        # Invalidate read cache for this table after compaction
        PRZMA.PzDbV2.ReadCache.invalidate_table(did, service, space, table)
        %{state |
          compactions_run:  state.compactions_run + 1,
          last_compact_at:  DateTime.utc_now(),
        }
      {:error, :backpressure} ->
        Logger.warning("Compaction skipped — writer backpressure", did: did, table: table)
        state
      {:error, msg} ->
        Logger.error("Compaction failed", did: did, table: table, error: msg)
        %{state | compactions_failed: state.compactions_failed + 1}
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_all, @check_interval_ms)
  end
end
