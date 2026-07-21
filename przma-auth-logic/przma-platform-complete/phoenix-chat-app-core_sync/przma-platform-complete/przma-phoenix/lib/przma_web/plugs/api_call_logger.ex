defmodule PRZMAWeb.Plugs.ApiCallLogger do
  import Plug.Conn
  alias PRZMA.PzDb

  def init(opts), do: opts

  def call(conn, _opts) do
    start = System.monotonic_time()

    register_before_send(conn, fn conn ->
      duration_ms = System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
      did = conn.assigns[:did] || "anonymous"

      record = %{
        "id"          => Ecto.UUID.generate(),
        "did"         => did,
        "method"      => conn.method,
        "path"        => conn.request_path,
        "status_code" => conn.status,
        "success"     => conn.status < 400,
        "duration_ms" => duration_ms,
        "called_at"   => System.os_time(:microsecond)
      }

      Task.start(fn ->
        uri = "pzdb://#{did}/telemetry/core/api_call_logs"
        PzDb.ensure_table(uri)
        PzDb.write(uri, record)
      end)

      conn
    end)
  end
end