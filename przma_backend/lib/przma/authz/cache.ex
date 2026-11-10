defmodule Przma.Authz.Cache do
  @moduledoc """
  Small in-memory cache (ETS) for the authorisation layer, so a request
  does not hit Postgres every time.

    * access profiles    {:profile, did}        — TTL `profile_ttl_ms` (default 60 s)
    * storage locations  {:location, did}       — same TTL; the last known value is
                                                  kept as a fallback if Postgres is down
    * sessions           {:session, sid}        — same TTL
    * access keys        {:key, key_hash}       — same TTL
    * endpoint registry  :endpoints             — same TTL

  Owned by this GenServer so the tables live as long as the app.
  invalidate/1 is called after every change (plan, role, suspension,
  key revoke …) so the change takes effect at once on this node, and
  within one TTL on any other node.
  """
  use GenServer

  @table :przma_authz_cache
  @counters :przma_authz_counters

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@counters, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  def counters_table, do: @counters

  @doc "Cached value or :miss. Entries older than the TTL count as a miss."
  def get(key, ttl_ms \\ ttl()) do
    case lookup(key) do
      {value, at} -> if now_ms() - at <= ttl_ms, do: {:ok, value}, else: :miss
      nil -> :miss
    end
  end

  @doc "Cached value regardless of age (fallback when Postgres is unreachable)."
  def get_stale(key) do
    case lookup(key) do
      {value, _at} -> {:ok, value}
      nil -> :miss
    end
  end

  def put(key, value) do
    if table?(), do: :ets.insert(@table, {key, value, now_ms()})
    value
  end

  def delete(key) do
    if table?(), do: :ets.delete(@table, key)
    :ok
  end

  @doc "Drops everything cached for one user."
  def invalidate(did) when is_binary(did) do
    delete({:profile, did})
    delete({:location, did})
    :ok
  end

  def clear do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Reads through the cache: returns the cached value or calls fun and caches {:ok, v}."
  def fetch(key, fun) do
    case get(key) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fun.() do
          {:ok, value} ->
            put(key, value)
            {:ok, value}

          other ->
            other
        end
    end
  end

  def ttl, do: Keyword.get(Application.get_env(:przma, :authz, []), :profile_ttl_ms, 60_000)

  def now_ms, do: System.monotonic_time(:millisecond)

  defp lookup(key) do
    if table?() do
      case :ets.lookup(@table, key) do
        [{^key, value, at}] -> {value, at}
        [] -> nil
      end
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined
end
