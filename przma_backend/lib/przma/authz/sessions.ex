defmodule Przma.Authz.Sessions do
  @moduledoc """
  Login sessions, keyed by Keycloak's session id (`sid` in the JWT).

  Keycloak's access token lives 24 h and is refreshed in the background,
  so the token alone cannot enforce "basic users log in again every 7
  days". This module does, per role (`session_policies`):

    * max session  — now − auth_time > max_session_seconds  → session_expired
    * idle timeout — no call for idle_timeout_seconds      → session_expired
    * max devices  — a new login beyond max_devices revokes the oldest
    * revoke       — an admin (or the user) sets revoked_at → session_revoked

  auth_time comes from the token when Keycloak sends it, otherwise from
  the first time PRZMA saw that sid. Rows are cached 60 s and
  last_seen_at is written at most once a minute.
  """

  alias Przma.Authz.{Cache, Db, Telemetry}

  @touch_every_s 60

  @doc """
  Checks the session behind a JWT call. `meta` = %{sid, claims, ip, user_agent}.
  Returns :ok | {:error, :session_expired | :session_revoked}.
  """
  def check(%{did: did, policy: policy}, %{sid: sid} = meta) when is_binary(sid) do
    with {:ok, row} <- fetch_or_create(did, sid, meta, policy) do
      now = System.system_time(:second)
      auth_time = to_unix(row.auth_time)
      last_seen = to_unix(row.last_seen_at)

      cond do
        row.did != did ->
          {:error, :session_revoked}

        row.revoked_at != nil ->
          {:error, :session_revoked}

        now - auth_time > policy.max_session_seconds ->
          close(sid, "max_session")
          {:error, :session_expired}

        now - last_seen > policy.idle_timeout_seconds ->
          close(sid, "idle_timeout")
          {:error, :session_expired}

        true ->
          maybe_touch(row, now, meta)
          :ok
      end
    end
  end

  # Tokens without a sid (e.g. service clients) have no session to track.
  def check(_profile, _meta), do: :ok

  @doc "Active sessions of one user, newest first."
  def list(did) do
    Db.all(
      """
      SELECT sid, device, host(ip) AS ip, user_agent, auth_time, created_at, last_seen_at,
             revoked_at, revoked_reason
        FROM przma_authz.sessions
       WHERE did = $1 AND revoked_at IS NULL
       ORDER BY last_seen_at DESC
      """,
      [did]
    )
  end

  @doc "Revokes one session of `did` (the user's own logout of another device)."
  def revoke(did, sid, reason \\ "user_logout") do
    result =
      Db.all(
        """
        UPDATE przma_authz.sessions SET revoked_at = now(), revoked_reason = $3
         WHERE did = $1 AND sid = $2 AND revoked_at IS NULL
        RETURNING sid
        """,
        [did, sid, reason]
      )

    Cache.delete({:session, sid})

    case result do
      {:ok, [_ | _]} -> {:ok, true}
      {:ok, []} -> {:error, :not_found}
      err -> err
    end
  end

  @doc "Revokes every session of `did` (admin action). Returns {:ok, count}."
  def revoke_all(did, reason) do
    with {:ok, rows} <-
           Db.all(
             """
             UPDATE przma_authz.sessions SET revoked_at = now(), revoked_reason = $2
              WHERE did = $1 AND revoked_at IS NULL
             RETURNING sid
             """,
             [did, reason]
           ) do
      Enum.each(rows, &Cache.delete({:session, &1.sid}))
      {:ok, length(rows)}
    end
  end

  # ── internals ─────────────────────────────────────────────────────────

  defp fetch_or_create(did, sid, meta, policy) do
    case Cache.get({:session, sid}) do
      {:ok, row} ->
        {:ok, row}

      :miss ->
        case Db.one(select_sql(), [sid]) do
          {:ok, nil} -> create(did, sid, meta, policy)
          {:ok, row} -> {:ok, Cache.put({:session, sid}, row)}
          {:error, _} = err -> err
        end
    end
  end

  defp create(did, sid, meta, policy) do
    auth_time =
      case meta[:claims] do
        %{"auth_time" => t} when is_integer(t) -> DateTime.from_unix!(t)
        _ -> DateTime.utc_now()
      end

    with {:ok, row} <-
           Db.one(
             """
             INSERT INTO przma_authz.sessions (sid, did, device, ip, user_agent, auth_time)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (sid) DO UPDATE SET last_seen_at = przma_authz.sessions.last_seen_at
             RETURNING sid, did, auth_time, last_seen_at, revoked_at
             """,
             [sid, did, device(meta[:user_agent]), Db.inet(meta[:ip]), meta[:user_agent], auth_time]
           ) do
      enforce_max_devices(did, sid, policy, meta)
      {:ok, Cache.put({:session, sid}, row)}
    end
  end

  # A new login beyond the role's device limit revokes the oldest sessions.
  defp enforce_max_devices(did, new_sid, %{max_devices: max}, meta) when is_integer(max) and max > 0 do
    case Db.all(
           """
           UPDATE przma_authz.sessions SET revoked_at = now(), revoked_reason = 'max_devices'
            WHERE sid IN (
              SELECT sid FROM przma_authz.sessions
               WHERE did = $1 AND revoked_at IS NULL AND sid <> $2
               ORDER BY last_seen_at DESC
               OFFSET $3)
           RETURNING sid
           """,
           [did, new_sid, max - 1]
         ) do
      {:ok, [_ | _] = rows} ->
        Enum.each(rows, &Cache.delete({:session, &1.sid}))

        Telemetry.security_event(%{
          did: did,
          type: :session_revoked,
          severity: "low",
          ip: meta[:ip],
          details: %{reason: "max_devices", revoked_sids: Enum.map(rows, & &1.sid), max_devices: max},
          action: "oldest_sessions_revoked"
        })

      _ ->
        :ok
    end
  end

  defp enforce_max_devices(_did, _sid, _policy, _meta), do: :ok

  defp close(sid, reason) do
    Db.exec(
      "UPDATE przma_authz.sessions SET revoked_at = now(), revoked_reason = $2 WHERE sid = $1 AND revoked_at IS NULL",
      [sid, reason]
    )

    Cache.delete({:session, sid})
  end

  defp maybe_touch(row, now, meta) do
    if now - to_unix(row.last_seen_at) >= @touch_every_s do
      Cache.put({:session, row.sid}, %{row | last_seen_at: DateTime.from_unix!(now)})

      Db.exec(
        "UPDATE przma_authz.sessions SET last_seen_at = now(), ip = COALESCE($2, ip) WHERE sid = $1",
        [row.sid, Db.inet(meta[:ip])]
      )
    end

    :ok
  end

  defp select_sql do
    "SELECT sid, did, auth_time, last_seen_at, revoked_at FROM przma_authz.sessions WHERE sid = $1"
  end

  defp to_unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp to_unix(%NaiveDateTime{} = ndt), do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp device(nil), do: nil

  defp device(ua) do
    cond do
      ua =~ "Android" -> "Android"
      ua =~ "iPhone" or ua =~ "iPad" -> "iOS"
      ua =~ "Windows" -> "Windows"
      ua =~ "Mac OS" -> "Mac"
      ua =~ "Linux" -> "Linux"
      ua =~ "curl" -> "curl"
      true -> String.slice(ua, 0, 40)
    end
  end
end
