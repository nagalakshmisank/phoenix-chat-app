defmodule PRZMAWeb.ApiCallLogController do
  use PRZMAWeb, :controller
  alias PRZMA.PzDb

  def mine(conn, params) do
    did = conn.assigns[:did]
    filter = build_filter(params)

    case PzDb.query("pzdb://#{did}/telemetry/core/api_call_logs", filter: filter, limit: 500) do
      {:ok, %{"records" => records}} -> json(conn, %{count: length(records), data: records})
      {:error, reason} -> conn |> put_status(500) |> json(%{error: reason})
    end
  end

  def mine_summary(conn, _params) do
    did = conn.assigns[:did]

    case PzDb.query("pzdb://#{did}/telemetry/core/api_call_logs", limit: 10_000) do
      {:ok, %{"records" => records}} ->
        total  = length(records)
        failed = Enum.count(records, &(&1["success"] == false))

        json(conn, %{
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