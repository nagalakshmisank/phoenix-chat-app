defmodule Przma.Social.Cache do
  @moduledoc """
  Tiny in-memory cache (ETS) for values that almost never change, such
  as a user's account record. Purely an optimisation: every function is
  safe to call when the table does not exist (it just misses).
  """

  @table :przma_social_cache

  @doc "Creates the table. Called once from Przma.Application.start/2."
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
