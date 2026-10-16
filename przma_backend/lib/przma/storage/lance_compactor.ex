defmodule Przma.Storage.LanceCompactor do
  @moduledoc """
  Keeps doc tables fast and S3 tidy.

  Every Lance write is a new version: a manifest in `_versions/`, a small
  data file in `data/` and, for updates, a file in `_deletions/`. Heavy chat
  makes thousands of tiny files per table, and reads slow down because they
  have to open all of them. This process periodically:

    1. compacts the small files of each busy table into bigger ones, and
    2. prunes versions older than `keep_versions_hours`.

  Which tables: LanceDocAdapter calls mark_dirty/2 after every successful
  write; each pass compacts the tables with at least `compact_min_writes`
  writes since their last compaction. Each compaction runs inside the
  table owner's DocWriter, so it never overlaps a write to that table.

  Config (config :przma, :lance_doc — see runtime.exs):
    compact_interval_min   minutes between passes, 0 = never automatically
    compact_min_writes     writes needed before a table is compacted
    keep_versions_hours    versions younger than this are kept (time travel)

  Manual use (iex), e.g. during tests:
      Przma.Storage.LanceCompactor.pending()      # tables waiting + write counts
      Przma.Storage.LanceCompactor.run_now()      # compact them now (ignores min writes)
  """

  use GenServer
  require Logger

  alias Przma.Storage.DocWriter

  @dirty :przma_lance_dirty

  # ── public API ───────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Counts one write to a table. Cheap (ETS); safe if the compactor is not running."
  @spec mark_dirty(String.t(), String.t()) :: :ok
  def mark_dirty(did, table_uri) do
    :ets.update_counter(@dirty, {did, table_uri}, {2, 1}, {{did, table_uri}, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Tables with uncompacted writes: [{did, table_uri, writes}]."
  def pending do
    for {{did, uri}, n} <- :ets.tab2list(@dirty), do: {did, uri, n}
  rescue
    ArgumentError -> []
  end

  @doc "Runs a pass now for every dirty table (ignores compact_min_writes)."
  def run_now, do: GenServer.call(__MODULE__, :run_now, :infinity)

  @doc "Compacts one table now (also used by LanceDocAdapter.compact/1)."
  @spec compact_table(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def compact_table(did, table_uri) do
    keep = cfg(:keep_versions_hours, 1)

    # Search tables (pzdb://did/search/…) have the vector schema, not the doc schema.
    optimize =
      if String.contains?(table_uri, "/search/"),
        do: &PRZMA.PzDb.vec_optimize/2,
        else: &PRZMA.PzDb.doc_optimize/2

    DocWriter.run(did, fn -> optimize.(table_uri, keep) end)
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@dirty, [:named_table, :public, :set, write_concurrency: true])
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:run_now, _from, state), do: {:reply, pass(1), state}

  @impl true
  def handle_info(:tick, state) do
    pass(cfg(:compact_min_writes, 50))
    schedule()
    {:noreply, state}
  end

  defp pass(min_writes) do
    for {{did, uri} = key, n} <- :ets.tab2list(@dirty), n >= min_writes do
      :ets.delete(@dirty, key)
      started = System.monotonic_time(:millisecond)

      case compact_table(did, uri) do
        {:ok, stats} ->
          ms = System.monotonic_time(:millisecond) - started
          Logger.info("Lance compacted #{uri} (#{n} writes) in #{ms}ms: #{inspect(stats)}")
          {uri, :ok}

        {:error, reason} ->
          # Put it back so the next pass retries.
          mark_dirty(did, uri)
          Logger.warning("Lance compaction failed for #{uri}: #{inspect(reason)}")
          {uri, {:error, reason}}
      end
    end
  end

  defp schedule do
    case cfg(:compact_interval_min, 30) do
      n when is_integer(n) and n > 0 -> Process.send_after(self(), :tick, n * 60_000)
      _ -> :disabled
    end
  end

  defp cfg(key, default), do: Keyword.get(Application.get_env(:przma, :lance_doc, []), key, default)
end
