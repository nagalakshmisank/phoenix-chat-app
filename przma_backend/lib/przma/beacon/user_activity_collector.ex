defmodule Przma.Beacon.UserActivityCollector do
  @moduledoc """
  Collects user activity for Beacon CMS and writes it to becam_cms.

  Two sources feed it:

  1. EVERY HTTP response (telemetry event `[:phoenix, :endpoint, :stop]`,
     already emitted by Plug.Telemetry in endpoint.ex — no controller
     changes). From each request we learn:
       * who the user is (KeycloakAuth put `did` + `token_claims` on the conn)
         -> przma_users: username, name, tier, last seen, request count
       * a Keycloak session we have not seen before      -> "signed_in"
       * a Bearer token that was rejected with 401        -> "auth_failed"

  2. `Przma.Beacon.track/3`, called by business code after a real
     success (registration, profile create/update)       -> that event

  Everything is buffered in memory and written every 2 seconds with
  one INSERT per table, so requests are never slowed down. If Postgres
  is unreachable the batch is logged and dropped (telemetry is
  best-effort) and the buffer is capped so memory can't grow forever.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias Przma.Beacon.{PrzmaUser, Repo, UserEvent}

  @handler_id "przma-beacon-user-activity"
  @flush_every_ms 2_000
  @max_events 5_000

  # ── public API ──────────────────────────────────────────────────────────

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queue one user event (used by Przma.Beacon.track/3)."
  def record(event), do: GenServer.cast(__MODULE__, {:event, event})

  @doc "Write everything buffered right now (handy in iex and tests)."
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc false
  # Runs inside the request process — must be cheap and must never raise
  # (a crashing telemetry handler gets detached and tracking would stop).
  def handle_telemetry([:phoenix, :endpoint, :stop], _measurements, %{conn: conn}, _config) do
    case observe(conn) do
      nil -> :ok
      observation -> GenServer.cast(__MODULE__, {:request, observation})
    end
  rescue
    error -> Logger.warning("[beacon] user activity not recorded: #{inspect(error)}")
  end

  def handle_telemetry(_event, _measurements, _metadata, _config), do: :ok

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:phoenix, :endpoint, :stop],
        &__MODULE__.handle_telemetry/4,
        nil
      )

    Process.send_after(self(), :flush, @flush_every_ms)
    {:ok, Map.put(empty_state(), :seen_sessions, MapSet.new())}
  end

  @impl true
  def handle_cast({:event, event}, state), do: {:noreply, add_event(state, event)}

  def handle_cast({:request, obs}, state) do
    state =
      if obs.did do
        state
        |> touch_user(obs)
        |> maybe_signed_in(obs)
      else
        state
      end

    state = if obs.auth_failed, do: add_event(state, obs.auth_failed), else: state
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl true
  def handle_info(:flush, state) do
    Process.send_after(self(), :flush, @flush_every_ms)
    {:noreply, write(state)}
  end

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach(@handler_id)
    write(state)
    :ok
  end

  # ── building observations from a finished request ─────────────────────

  @doc false
  def observe(conn) do
    claims = conn.assigns[:token_claims]
    did = conn.assigns[:did]
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    ua = conn |> Plug.Conn.get_req_header("user-agent") |> List.first() |> truncate(300)

    cond do
      is_binary(did) and is_map(claims) ->
        %{
          did: did,
          username: claims["preferred_username"] || Przma.Beacon.username_from_did(did),
          display_name: claims["name"],
          email: if(store_email?(), do: claims["email"]),
          tier: conn.assigns[:storage_tier],
          session_id: claims["sid"] || claims["session_state"],
          ip: ip,
          user_agent: ua,
          at: DateTime.utc_now(),
          auth_failed: nil
        }

      conn.status == 401 ->
        case conn |> Plug.Conn.get_req_header("authorization") |> List.first() do
          "Bearer " <> token -> %{did: nil, auth_failed: auth_failed_event(token, conn, ip, ua)}
          _ -> nil
        end

      true ->
        nil
    end
  end

  # The token was REJECTED, so its claims are not trusted. We only peek at
  # them (no signature check) to show *who it claims to be* and whether it
  # simply expired. The admin page marks these as unverified.
  defp auth_failed_event(token, conn, ip, ua) do
    claims = unverified_claims(token)
    username = claims["preferred_username"]
    expired? = is_integer(claims["exp"]) and claims["exp"] < System.system_time(:second)

    %{
      occurred_at: DateTime.utc_now(),
      did: if(is_binary(username), do: "did:przma:" <> username),
      username: username,
      event_type: "auth_failed",
      session_id: nil,
      details: %{
        reason: if(expired?, do: "token_expired", else: "token_invalid"),
        verified: false,
        path: conn.request_path
      },
      ip: ip,
      user_agent: ua
    }
  end

  defp unverified_claims(token) do
    with [_, payload, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, %{} = claims} <- Jason.decode(json) do
      claims
    else
      _ -> %{}
    end
  end

  # ── state helpers ───────────────────────────────────────────────────────

  defp empty_state, do: %{events: [], event_count: 0, users: %{}, dropped: 0}

  defp add_event(%{event_count: n} = state, _event) when n >= @max_events,
    do: %{state | dropped: state.dropped + 1}

  defp add_event(state, event),
    do: %{state | events: [event | state.events], event_count: state.event_count + 1}

  # One aggregated row per DID per batch (Postgres can't update the same
  # row twice in one INSERT ... ON CONFLICT).
  defp touch_user(state, obs) do
    row = %{
      did: obs.did,
      username: obs.username,
      display_name: obs.display_name,
      email: obs.email,
      tier: obs.tier,
      first_seen_at: obs.at,
      last_seen_at: obs.at,
      request_count: 1,
      last_ip: obs.ip,
      last_user_agent: obs.user_agent,
      updated_at: obs.at
    }

    users =
      Map.update(state.users, obs.did, row, fn existing ->
        %{row | first_seen_at: existing.first_seen_at, request_count: existing.request_count + 1}
      end)

    %{state | users: users}
  end

  # "signed_in" = first request carrying a Keycloak session id we haven't
  # recorded for this user. A unique index on (did, session_id) for
  # signed_in rows makes repeats (and app restarts) harmless.
  defp maybe_signed_in(state, %{session_id: sid} = obs) when is_binary(sid) do
    key = {obs.did, sid}

    if MapSet.member?(state.seen_sessions, key) do
      state
    else
      state
      |> remember_session(key)
      |> add_event(signed_in_event(obs, sid))
    end
  end

  defp maybe_signed_in(state, _obs), do: state

  # Memory of sessions already reported, so we don't queue a signed_in on
  # every request. Reset when large; the DB unique index still guarantees
  # one row per session (also across restarts).
  defp remember_session(%{seen_sessions: seen} = state, key) do
    seen = if MapSet.size(seen) >= 50_000, do: MapSet.new(), else: seen
    %{state | seen_sessions: MapSet.put(seen, key)}
  end

  defp signed_in_event(obs, sid) do
    %{
      occurred_at: obs.at,
      did: obs.did,
      username: obs.username,
      event_type: "signed_in",
      session_id: sid,
      details: %{tier: obs.tier},
      ip: obs.ip,
      user_agent: obs.user_agent
    }
  end

  # ── writing ─────────────────────────────────────────────────────────────

  defp write(%{event_count: 0, users: users} = state) when map_size(users) == 0, do: state

  defp write(state) do
    write_users(Map.values(state.users))
    write_events(Enum.reverse(state.events))

    if state.dropped > 0,
      do: Logger.warning("[beacon] buffer full, dropped #{state.dropped} user events")

    Map.merge(state, empty_state())
  end

  defp write_users([]), do: :ok

  defp write_users(rows) do
    upsert =
      from(u in PrzmaUser,
        update: [
          set: [
            username: fragment("EXCLUDED.username"),
            display_name: fragment("COALESCE(EXCLUDED.display_name, ?)", u.display_name),
            email: fragment("COALESCE(EXCLUDED.email, ?)", u.email),
            tier: fragment("COALESCE(EXCLUDED.tier, ?)", u.tier),
            last_seen_at: fragment("GREATEST(?, EXCLUDED.last_seen_at)", u.last_seen_at),
            request_count: fragment("? + EXCLUDED.request_count", u.request_count),
            last_ip: fragment("EXCLUDED.last_ip"),
            last_user_agent: fragment("EXCLUDED.last_user_agent"),
            updated_at: fragment("EXCLUDED.updated_at")
          ]
        ]
      )

    Repo.insert_all(PrzmaUser, rows, on_conflict: upsert, conflict_target: :did)
  rescue
    error -> Logger.error("[beacon] could not save #{length(rows)} users: #{Exception.message(error)}")
  end

  defp write_events([]), do: :ok

  defp write_events(rows) do
    # :nothing skips duplicate signed_in rows (unique index), keeps the rest
    Repo.insert_all(UserEvent, rows, on_conflict: :nothing)
  rescue
    error -> Logger.error("[beacon] dropped #{length(rows)} user events: #{Exception.message(error)}")
  end

  defp store_email?, do: System.get_env("BEACON_STORE_EMAIL", "false") == "true"

  defp truncate(nil, _max), do: nil
  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max)
end
