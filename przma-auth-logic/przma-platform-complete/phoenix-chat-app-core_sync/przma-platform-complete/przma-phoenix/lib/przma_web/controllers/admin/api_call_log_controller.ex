defmodule PRZMAWeb.Admin.ApiCallLogController do
  use PRZMAWeb, :controller
  alias PRZMA.PzDb

  def index(conn, %{"did" => did} = params) do
    filter = build_filter(params)

    case PzDb.query("pzdb://#{did}/telemetry/core/api_call_logs", filter: filter, limit: 500) do
      {:ok, %{"records" => records}} -> json(conn, %{did: did, count: length(records), data: records})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: reason})
    end
  end

  def index(conn, _params) do
    conn |> put_status(400) |> json(%{error: "did query param is required"})
  end

  def summary(conn, %{"did" => did}) do
    case PzDb.query("pzdb://#{did}/telemetry/core/api_call_logs", limit: 10_000) do
      {:ok, %{"records" => records}} ->
        total  = length(records)
        failed = Enum.count(records, &(&1["success"] == false))

        json(conn, %{
          did: did,
          total_calls: total,
          successful: total - failed,
          failed: failed,
          success_rate_pct: pct(total - failed, total),
          avg_duration_ms: avg(Enum.map(records, & &1["duration_ms"]))
        })

      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: reason})
    end
  end

  defp build_filter(%{"success" => s}), do: "success = #{s == "true"}"
  defp build_filter(_), do: ""
  defp pct(_num, 0), do: 0.0
  defp pct(num, denom), do: Float.round(num / denom * 100, 1)
  defp avg([]), do: 0
  defp avg(list), do: Float.round(Enum.sum(list) / length(list), 1)
end