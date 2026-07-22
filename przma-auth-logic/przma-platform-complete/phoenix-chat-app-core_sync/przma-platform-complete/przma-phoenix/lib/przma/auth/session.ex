defmodule PRZMA.Auth.Session do
  @moduledoc """
  Login-session bookkeeping for logout/revoke. Never on the request-auth
  read path (that's Phoenix.Token verification, zero I/O) — only used when
  you explicitly want to see/kill sessions.
  """

  alias PRZMA.PzDb
  require Logger

  defp session_uri(did, id), do: "pzdb://#{did}/auth/core/sessions/#{id}"
  defp sessions_table_uri(did), do: "pzdb://#{did}/auth/core/sessions/_"

  def create(did, conn_info) do
    id = generate_id()
    now = System.os_time(:microsecond)

    record = %{
      "id" => id,
      "did" => did,
      "device" => conn_info[:device],
      "ip_address" => conn_info[:ip_address],
      "user_agent" => conn_info[:user_agent],
      "issued_at" => now,
      "last_active_at" => now,
      "revoked_at" => nil  # must be present (even as NULL) on the first write —
                            # otherwise Lance's inferred schema never gets this
                            # column, and list_active's "revoked_at IS NULL"
                            # filter silently matches nothing instead of
                            # matching the active session
    }

    with :ok <- PzDb.ensure_table(session_uri(did, id)),
         {:ok, _} <- PzDb.write(session_uri(did, id), record) do
      {:ok, id}
    end
  end

  def list_active(did) do
    case PzDb.query(sessions_table_uri(did), filter: "revoked_at IS NULL", limit: 200) do
      {:ok, %{"records" => records}} -> {:ok, records}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke(did, session_id) do
    with {:ok, row} <- read_row(did, session_id) do
      now = System.os_time(:microsecond)
      merged = Map.merge(row, %{"revoked_at" => now})
      PzDb.write(session_uri(did, session_id), merged)
    end
  end

  def revoke_all(did) do
    with {:ok, rows} <- list_active(did) do
      now = System.os_time(:microsecond)

      failures =
        rows
        |> Enum.map(fn row ->
          merged = Map.merge(row, %{"revoked_at" => now})
          {row["id"], PzDb.write(session_uri(did, row["id"]), merged)}
        end)
        |> Enum.reject(fn {_id, result} -> match?({:ok, _}, result) end)

      if failures != [] do
        Logger.warning("[Session] revoke_all partial failure did=#{did} failures=#{inspect(failures)}")
      end

      :ok
    end
  end

  @doc "Extract device/IP/user_agent from a conn for the sessions row."
  def conn_info(conn) do
    ip =
      case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] -> forwarded |> String.split(",") |> List.first() |> String.trim()
        [] -> conn.remote_ip |> :inet.ntoa() |> List.to_string()
      end

    ua = Plug.Conn.get_req_header(conn, "user-agent") |> List.first("")

    device =
      cond do
        String.contains?(ua, "Mobile") -> "mobile"
        String.contains?(ua, "Tablet") -> "tablet"
        String.contains?(ua, "curl") -> "api_client"
        ua == "" -> "unknown"
        true -> "desktop"
      end

    %{ip_address: ip, user_agent: ua, device: device}
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp read_row(did, session_id) do
    case PzDb.query(session_uri(did, session_id), filter: "id = '#{esc(session_id)}'", limit: 1) do
      {:ok, %{"records" => [row | _]}} -> {:ok, row}
      {:ok, %{"records" => []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(15) |> Base.url_encode64(padding: false)
  defp esc(s), do: String.replace(s, "'", "''")
end