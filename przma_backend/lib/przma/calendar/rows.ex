defmodule Przma.Calendar.Rows do
  @moduledoc """
  Reads ALL rows of a calendar table that start with a prefix.
  Store.list/4 returns at most 1000 rows per call, so this pages with
  the :after cursor (ids are sorted) until a short page comes back.
  """

  alias Przma.Social.Store

  @page 1000
  @max_pages 50

  def all(did, table, prefix, opts \\ []), do: loop(did, table, prefix, nil, [], opts, 0)

  defp loop(_did, _table, _prefix, _after, acc, _opts, @max_pages), do: {:ok, acc}

  defp loop(did, table, prefix, after_id, acc, opts, n) do
    range = [prefix: prefix, limit: @page] ++ if(after_id, do: [after: after_id], else: [])

    case Store.list(did, "calendar", table, range ++ opts) do
      {:ok, rows} when length(rows) == @page ->
        loop(did, table, prefix, List.last(rows)["id"], acc ++ rows, opts, n + 1)

      {:ok, rows} ->
        {:ok, acc ++ rows}

      err ->
        err
    end
  end
end
