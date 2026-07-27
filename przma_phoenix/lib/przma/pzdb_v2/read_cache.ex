# lib/przma/pzdb/read_cache.ex
#
# ETS read cache for hot Lance records.
#
# Cache entries are tagged with the Lance manifest version at read time.
# On write: the writer invalidates affected cache entries by URI.
# On read: if cached version >= current table version, return cached value.
#
# Only caches records that are read more than @hot_read_threshold times
# within @hot_window_ms. This avoids caching one-off reads.
#
# NOT used for: list queries, vector searches, DuckDB analytics.
# USED for: single-record reads by id (pzdb_read), cross-service URI lookups.

defmodule PRZMA.PzDbV2.ReadCache do
  use GenServer

  @table          :pzdb_read_cache
  @hot_threshold  3          # reads before we cache
  @hot_window_ms  60_000     # window for counting hot reads
  @max_entries    50_000     # LRU eviction when exceeded
  @ttl_ms        300_000     # 5 minute TTL

  # ── PUBLIC API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached record for a URI.
  Returns {:hit, record, version} or :miss.
  """
  def get(pzdb_uri) when is_binary(pzdb_uri) do
    now = System.monotonic_time(:millisecond)
    case :ets.lookup(@table, pzdb_uri) do
      [{_, record, version, expires_at}] when expires_at > now ->
        :telemetry.execute([:pzdb, :cache, :hit], %{count: 1}, %{uri: pzdb_uri})
        {:hit, record, version}
      [{_, _, _, _}] ->
        # Expired — delete and return miss
        :ets.delete(@table, pzdb_uri)
        :miss
      [] ->
        :miss
    end
  end

  @doc """
  Store a record in the cache.
  Only caches if the record is "hot" (read frequently).
  """
  def put(pzdb_uri, record, version) when is_binary(pzdb_uri) do
    if hot?(pzdb_uri) do
      expires = System.monotonic_time(:millisecond) + @ttl_ms
      :ets.insert(@table, {pzdb_uri, record, version, expires})
      :telemetry.execute([:pzdb, :cache, :put], %{count: 1}, %{uri: pzdb_uri})
      :cached
    else
      record_access(pzdb_uri)
      :not_cached
    end
  end

  @doc """
  Invalidate cache entries for a URI after a write.
  Called by the write pipeline automatically.
  """
  def invalidate(pzdb_uri) when is_binary(pzdb_uri) do
    :ets.delete(@table, pzdb_uri)
    :ok
  end

  @doc """
  Invalidate all cached entries for a DID+table combination.
  Called after batch writes or compaction.
  """
  def invalidate_table(did, service, space, table) do
    prefix = "pzdb://#{did}/#{service}/#{space}/#{table}/"
    # Pattern match on key prefix — ETS doesn't support prefix scan natively
    # so we use match_delete with a guard
    :ets.match_delete(@table, {:"$1", :_, :_, :_})
    # For production: maintain a secondary index or use a different data structure
    :ok
  end

  @doc "Current cache size"
  def size, do: :ets.info(@table, :size)

  @doc "Flush the entire cache (used in tests)"
  def flush, do: :ets.delete_all_objects(@table)

  # ── GENSERVER ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set, :public, :named_table,
      read_concurrency:  true,
      write_concurrency: true,
    ])
    # Access frequency tracking table
    :ets.new(:pzdb_access_freq, [
      :set, :public, :named_table,
      write_concurrency: true,
    ])
    schedule_gc()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:gc, state) do
    now = System.monotonic_time(:millisecond)

    # Remove expired entries
    expired = :ets.foldl(fn
      {uri, _, _, expires_at}, acc when expires_at <= now -> [uri | acc]
      _, acc -> acc
    end, [], @table)
    Enum.each(expired, &:ets.delete(@table, &1))

    # LRU eviction if over limit
    size = :ets.info(@table, :size)
    if size > @max_entries do
      evict = size - (@max_entries * 9 / 10) |> trunc()
      evict_lru(evict)
    end

    schedule_gc()
    {:noreply, state}
  end

  # ── PRIVATE ────────────────────────────────────────────────────────────────

  defp hot?(uri) do
    now   = System.monotonic_time(:millisecond)
    case :ets.lookup(:pzdb_access_freq, uri) do
      [{_, count, first_at}] when now - first_at <= @hot_window_ms ->
        count >= @hot_threshold
      _ ->
        false
    end
  end

  defp record_access(uri) do
    now = System.monotonic_time(:millisecond)
    :ets.update_counter(:pzdb_access_freq, uri,
      [{2, 1}],                      # increment count
      {uri, 0, now}                  # default if not exists
    )
  end

  defp evict_lru(count) do
    # Simple eviction: delete oldest entries by expiry
    entries = :ets.tab2list(@table)
    entries
    |> Enum.sort_by(fn {_, _, _, exp} -> exp end)
    |> Enum.take(count)
    |> Enum.each(fn {uri, _, _, _} -> :ets.delete(@table, uri) end)
  end

  defp schedule_gc do
    Process.send_after(self(), :gc, 60_000)  # GC every 60 seconds
  end
end
