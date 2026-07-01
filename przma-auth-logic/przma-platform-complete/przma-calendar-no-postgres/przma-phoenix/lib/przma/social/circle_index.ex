# lib/przma/social/circle_index.ex
#
# In-memory ETS index of circle → [member_dids].
# Source of truth is always Lance (social/core/memberships.lance in each user's vault).
# ETS is a read cache: fast O(1) lookup, rebuilt from Lance on startup.
#
# Invalidated on every membership change (add/remove/update role).
# On startup: scans all vault directories to reconstruct from Lance files.

defmodule PRZMA.Social.CircleIndex do
  use GenServer
  require Logger

  @table :przma_circle_index

  # ── PUBLIC API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "List all member DIDs for a circle"
  def member_dids(circle_did) do
    case :ets.lookup(@table, {:circle, circle_did}) do
      [{_, dids}] -> dids
      []          -> []
    end
  end

  @doc "List all circle DIDs a member belongs to"
  def circles_for(did) do
    case :ets.lookup(@table, {:member, did}) do
      [{_, circles}] -> circles
      []             -> []
    end
  end

  @doc "Get cached role for a (did, circle_did) pair"
  def role(did, circle_did) do
    case :ets.lookup(@table, {:role, did, circle_did}) do
      [{_, role}] -> {:ok, role}
      []          -> :error
    end
  end

  @doc """
  Add a membership to the index.
  Called by Identity.add_member/4 after writing to Lance.
  """
  def put(did, circle_did, role) do
    GenServer.cast(__MODULE__, {:put, did, circle_did, role})
  end

  @doc """
  Remove a membership from the index.
  Called by Identity.remove_member/3 after deactivating in Lance.
  """
  def remove(did, circle_did) do
    GenServer.cast(__MODULE__, {:remove, did, circle_did})
  end

  @doc "Full rebuild from Lance — called on startup and on vault import"
  def rebuild do
    GenServer.call(__MODULE__, :rebuild, 30_000)
  end

  # ── GENSERVER ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Rebuild asynchronously — don't block supervision tree startup
    send(self(), :rebuild)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:rebuild, _from, state) do
    count = do_rebuild()
    Logger.info("Circle index rebuilt from Lance", memberships: count)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_cast({:put, did, circle_did, role}, state) do
    upsert_entry(did, circle_did, role)
    {:noreply, state}
  end

  def handle_cast({:remove, did, circle_did}, state) do
    delete_entry(did, circle_did)
    {:noreply, state}
  end

  @impl true
  def handle_info(:rebuild, state) do
    count = do_rebuild()
    Logger.info("Circle index rebuilt", memberships: count)
    {:noreply, state}
  end

  # ── REBUILD LOGIC ────────────────────────────────────────────────────────

  defp do_rebuild do
    base_path = Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")

    # Scan vault directories to find all DIDs
    dids = vault_dids(base_path)
    count = Enum.reduce(dids, 0, fn did, acc ->
      memberships = load_memberships_from_lance(base_path, did)
      Enum.each(memberships, fn m ->
        if m["is_active"] do
          upsert_entry(m["did"], m["circle_did"], m["role"])
        end
      end)
      acc + length(memberships)
    end)
    count
  end

  defp vault_dids(base_path) do
    case File.ls(base_path) do
      {:ok, entries} ->
        Enum.filter(entries, fn e ->
          path = Path.join(base_path, e)
          File.dir?(path) and File.dir?(Path.join(path, "social/core"))
        end)
        |> Enum.map(fn dir_name ->
            # Convert filesystem-safe name back to DID
            # e.g. "did:web:alice.com" stays as-is if stored under UUID; adjust if using hashed names
            dir_name
          end)
      {:error, _} -> []
    end
  end

  defp load_memberships_from_lance(base_path, did) do
    # Read memberships Lance file via DuckDB
    lance_path = "#{base_path}/#{did}/social/core/memberships.lance"
    unless File.dir?(lance_path) do
      return []
    end

    conn = Duckdbex.open(":memory:") |> elem(1)
    Duckdbex.query(conn, "INSTALL lance; LOAD lance;")

    sql = "SELECT did, circle_did, role, is_active FROM scan_lance('#{lance_path}') WHERE is_active = true"
    case Duckdbex.query(conn, sql) do
      {:ok, result} ->
        result
        |> Duckdbex.fetch_all()
        |> Enum.map(fn [did, circle_did, role, is_active] ->
            %{"did" => did, "circle_did" => circle_did, "role" => role, "is_active" => is_active}
          end)
      {:error, _} -> []
    end
  end

  # ── ETS MUTATION HELPERS ─────────────────────────────────────────────────

  defp upsert_entry(did, circle_did, role) do
    # Role lookup
    :ets.insert(@table, {{:role, did, circle_did}, role})

    # circle → [member_dids]
    existing_members = case :ets.lookup(@table, {:circle, circle_did}) do
      [{_, dids}] -> dids
      []          -> []
    end
    updated_members = Enum.uniq([did | existing_members])
    :ets.insert(@table, {{:circle, circle_did}, updated_members})

    # member → [circle_dids]
    existing_circles = case :ets.lookup(@table, {:member, did}) do
      [{_, circles}] -> circles
      []             -> []
    end
    updated_circles = Enum.uniq([circle_did | existing_circles])
    :ets.insert(@table, {{:member, did}, updated_circles})
  end

  defp delete_entry(did, circle_did) do
    :ets.delete(@table, {:role, did, circle_did})

    case :ets.lookup(@table, {:circle, circle_did}) do
      [{_, dids}] ->
        :ets.insert(@table, {{:circle, circle_did}, List.delete(dids, did)})
      [] -> :ok
    end

    case :ets.lookup(@table, {:member, did}) do
      [{_, circles}] ->
        :ets.insert(@table, {{:member, did}, List.delete(circles, circle_did)})
      [] -> :ok
    end
  end
end
