defmodule Przma.Authz.Telemetry do
  @moduledoc """
  Usage counters, rate limits, security events and the audit log.

    * count/3 adds one API call (or error) to an in-memory counter;
      every 30 s the counters are added to `usage_daily`
      (did, day, service) in one upsert, so a busy user costs one write
      per 30 s, not one per request.
    * rate_limit/3 counts calls per user (or key) per API per minute.
    * security_event/1 and audit/1 write one row each, in the
      background (Przma.Authz.TaskSupervisor), never slowing a request.
    * abuse rule: when one access key collects `key_abuse_threshold`
      denied calls inside 10 minutes it is revoked automatically and a
      `key_abuse` event (severity high) is written.
  """
  use GenServer
  require Logger

  alias Przma.Authz.{Cache, Db}

  @flush_ms 30_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  # ── usage ─────────────────────────────────────────────────────────────

  @doc "One call for `did` on `service`; error? = true counts it as an error too."
  def count(did, service, error? \\ false)

  def count(did, service, error?) when is_binary(did) do
    key = {:usage, did, Date.utc_today(), service || "other"}
    bump(key, 2, 1)
    if error?, do: bump(key, 3, 1)
    :ok
  end

  def count(_did, _service, _error?), do: :ok

  @doc "Bytes written / read for storage telemetry."
  def bytes(did, service, written, read \\ 0) when is_binary(did) do
    key = {:usage, did, Date.utc_today(), service}
    if written > 0, do: bump(key, 4, written)
    if read > 0, do: bump(key, 5, read)
    :ok
  end

  # ── rate limit ────────────────────────────────────────────────────────

  @doc ":ok, or {:error, :rate_limited} when `who` passed `limit` calls to `endpoint` this minute."
  def rate_limit(_who, _endpoint, nil), do: :ok
  def rate_limit(_who, _endpoint, limit) when limit <= 0, do: :ok

  def rate_limit(who, endpoint, limit) do
    minute = div(System.system_time(:second), 60)
    n = bump({:rate, who, endpoint, minute}, 2, 1)
    if n > limit, do: {:error, :rate_limited}, else: :ok
  end

  # ── security events & audit ───────────────────────────────────────────

  @severity %{
    endpoint_not_registered: "low",
    endpoint_disabled: "low",
    account_not_registered: "low",
    scope_denied: "low",
    feature_not_in_plan: "low",
    session_expired: "low",
    session_revoked: "medium",
    account_suspended: "medium",
    rate_limited: "medium",
    quota_exceeded: "low",
    key_invalid: "medium",
    key_expired: "low",
    key_revoked: "medium",
    key_ip_not_allowed: "high",
    key_abuse: "high",
    storage_migrating: "low"
  }

  def severity(code), do: Map.get(@severity, code, "medium")

  @doc "Writes a security_events row in the background. Keys: did, key_id, type, ip, details, action."
  def security_event(%{type: type} = ev) do
    async(fn ->
      Db.exec(
        """
        INSERT INTO przma_authz.security_events
          (did, access_key_id, event_type, severity, ip, details, action_taken)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        """,
        [
          ev[:did],
          Db.uuid(ev[:key_id]),
          to_string(type),
          ev[:severity] || severity(type),
          Db.inet(ev[:ip]),
          ev[:details] || %{},
          ev[:action] || "none"
        ]
      )
    end)
  end

  @doc "Writes an audit_log row in the background. Keys: actor, action, target_type, target_id, before, after, ip."
  def audit(%{action: action} = a) do
    async(fn -> audit_now(Map.put(a, :action, action)) end)
  end

  @doc "Same as audit/1 but synchronous (used inside transactions)."
  def audit_now(a) do
    Db.exec(
      """
      INSERT INTO przma_authz.audit_log (actor_did, action, target_type, target_id, before, after, ip)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      [a[:actor], a.action, a[:target_type], a[:target_id], a[:before], a[:after], Db.inet(a[:ip])]
    )
  end

  @doc """
  Counts a denied call made with an access key; past the threshold in a
  10-minute window the key is revoked. Returns :revoked or :ok.
  """
  def key_denied(nil, _did, _ip), do: :ok

  def key_denied(key_id, did, ip) do
    window = div(System.system_time(:second), 600)
    n = bump({:key_fail, key_id, window}, 2, 1)
    threshold = Keyword.get(Application.get_env(:przma, :authz, []), :key_abuse_threshold, 50)

    if n == threshold do
      Przma.Authz.AccessKeys.revoke_system(key_id, "key_abuse")

      security_event(%{
        did: did,
        key_id: key_id,
        type: :key_abuse,
        ip: ip,
        details: %{denied_calls_10min: n},
        action: "key_revoked"
      })

      :revoked
    else
      :ok
    end
  end

  # ── GenServer: flush usage to Postgres, drop old rate counters ────────

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush()
    schedule()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, _state), do: flush()

  @doc "Writes the pending usage counters now (also used by tests)."
  def flush do
    table = Cache.counters_table()

    if :ets.whereis(table) != :undefined do
      # take/2 removes each row atomically, so a count made during the
      # flush is never lost (it simply starts a new row).
      keys = :ets.select(table, [{{{:usage, :_, :_, :_}, :_, :_, :_, :_}, [], [{:element, 1, :"$_"}]}])
      rows = Enum.flat_map(keys, &:ets.take(table, &1))
      write_usage(rows)
      drop_old_counters(table)
    end

    :ok
  end

  defp write_usage([]), do: :ok

  defp write_usage(rows) do
    cols =
      Enum.reduce(rows, {[], [], [], [], [], [], []}, fn {{:usage, did, day, svc}, calls, errs, bw, br},
                                                         {d, dy, s, c, e, w, r} ->
        {[did | d], [day | dy], [svc | s], [calls | c], [errs | e], [bw | w], [br | r]}
      end)

    {dids, days, svcs, calls, errs, bws, brs} = cols

    result =
      Db.exec(
        """
        INSERT INTO przma_authz.usage_daily AS u
          (did, day, service, api_calls, errors, bytes_written, bytes_read)
        SELECT t.did, t.day, t.service, t.calls, t.errs, t.bw, t.br
          FROM unnest($1::text[], $2::date[], $3::text[], $4::bigint[], $5::bigint[], $6::bigint[], $7::bigint[])
               AS t(did, day, service, calls, errs, bw, br)
          JOIN przma_authz.accounts a ON a.did = t.did
        ON CONFLICT (did, day, service) DO UPDATE SET
          api_calls     = u.api_calls + EXCLUDED.api_calls,
          errors        = u.errors + EXCLUDED.errors,
          bytes_written = u.bytes_written + EXCLUDED.bytes_written,
          bytes_read    = u.bytes_read + EXCLUDED.bytes_read
        """,
        [dids, days, svcs, calls, errs, bws, brs]
      )

    case result do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Authz: usage flush failed: #{inspect(reason)}")
    end
  end

  defp drop_old_counters(table) do
    minute = div(System.system_time(:second), 60)
    window = div(System.system_time(:second), 600)
    :ets.select_delete(table, [{{{:rate, :_, :_, :"$1"}, :_}, [{:<, :"$1", minute}], [true]}])
    :ets.select_delete(table, [{{{:key_fail, :_, :"$1"}, :_}, [{:<, :"$1", window}], [true]}])
  end

  defp schedule, do: Process.send_after(self(), :flush, @flush_ms)

  # Usage rows are {key, calls, errors, bytes_written, bytes_read};
  # rate / abuse rows are {key, count}.
  defp bump(key, pos, inc) do
    table = Cache.counters_table()

    if :ets.whereis(table) == :undefined do
      0
    else
      default =
        case key do
          {:usage, _, _, _} -> {key, 0, 0, 0, 0}
          _ -> {key, 0}
        end

      :ets.update_counter(table, key, {pos, inc}, default)
    end
  end

  defp async(fun) do
    if Process.whereis(Przma.Authz.TaskSupervisor) do
      Task.Supervisor.start_child(Przma.Authz.TaskSupervisor, fun)
    else
      fun.()
    end

    :ok
  end
end
