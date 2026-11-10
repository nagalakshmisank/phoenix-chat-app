defmodule PRZMAWeb.Graphql.Resolvers.AuthzResolver do
  @moduledoc """
  Resolvers for PRZMAWeb.Graphql.Types.AuthzTypes. Who may call what is
  already decided by the Authz middleware (myAccess: profile:rw,
  access keys: keys:manage, admin*: admin:*); these only do the work.
  """

  alias Przma.Authz.{AccessKeys, Admin, Profile, Sessions}

  # ── own access ────────────────────────────────────────────────────────

  def my_access(_args, %{context: %{did: did} = ctx}) when is_binary(did) do
    case Profile.load(did) |> found() do
      {:ok, %Profile{} = p} -> {:ok, profile_out(p, ctx[:auth_method])}
      err -> errors(err)
    end
  end

  def my_access(_, _), do: {:error, "unauthorized"}

  def my_sessions(_args, %{context: %{did: did} = ctx}) when is_binary(did) do
    result =
      with {:ok, rows} <- Sessions.list(did) do
      {:ok,
       Enum.map(rows, fn r ->
         %{
           sid: r.sid,
           device: r.device,
           ip: r.ip,
           user_agent: r.user_agent,
           auth_time: iso(r.auth_time),
           last_seen_at: iso(r.last_seen_at),
           current: r.sid == ctx[:sid]
         }
       end)}
      end

    errors(result)
  end

  def revoke_my_session(%{sid: sid}, %{context: %{did: did}}) when is_binary(did),
    do: Sessions.revoke(did, sid) |> errors()

  # ── access keys ───────────────────────────────────────────────────────

  def my_access_keys(_args, %{context: %{did: did}}) when is_binary(did) do
    case AccessKeys.list(did) do
      {:ok, rows} -> {:ok, Enum.map(rows, &key_out/1)}
      err -> errors(err)
    end
  end

  def create_access_key(args, %{context: %{did: did} = ctx}) when is_binary(did) do
    result =
      with {:ok, %Profile{} = p} <- Profile.load(did) |> found(),
           {:ok, %{key: key, access_key: row}} <- AccessKeys.create(p, args, ctx[:client_ip]) do
        {:ok, %{key: key, access_key: key_out(row)}}
      end

    errors(result)
  end

  def revoke_access_key(%{id: id}, %{context: %{did: did} = ctx}) when is_binary(did),
    do: AccessKeys.revoke(did, id, ctx[:client_ip]) |> errors()

  # ── admin ─────────────────────────────────────────────────────────────

  def admin_account(%{did: target}, _res) do
    case Admin.account(target) do
      {:ok, p} -> {:ok, profile_out(p, nil)}
      err -> errors(err)
    end
  end

  def admin_security_events(args, _res) do
    result =
      with {:ok, rows} <- Admin.security_events(args[:did], args[:limit]) do
      {:ok,
       Enum.map(rows, fn r ->
         %{
           id: to_string(r.id),
           did: r.did,
           access_key_id: r.access_key_id,
           event_type: r.event_type,
           severity: r.severity,
           ip: r.ip,
           details: Jason.encode!(r.details || %{}),
           action_taken: r.action_taken,
           created_at: iso(r.created_at)
         }
       end)}
      end

    errors(result)
  end

  def admin_set_plan(%{did: target, plan: plan}, %{context: %{did: admin}}),
    do: Admin.set_plan(admin, target, plan) |> errors()

  def admin_set_account_status(%{did: target, status: status} = args, %{context: %{did: admin}}),
    do: Admin.set_status(admin, target, status, args[:reason]) |> errors()

  def admin_revoke_sessions(%{did: target} = args, %{context: %{did: admin}}),
    do: Admin.revoke_sessions(admin, target, args[:reason]) |> errors()

  def admin_grant_feature(%{did: target, feature: f, source: s} = args, %{context: %{did: admin}}) do
    result =
      with {:ok, row} <- Admin.grant_feature(admin, target, f, s, args[:days]) do
        {:ok, %{feature_code: row.feature_code, source: row.source, valid_until: iso(row.valid_until)}}
      end

    errors(result)
  end

  def admin_migrate_storage(%{did: target, tier: tier}, %{context: %{did: admin}}),
    do: Admin.migrate_storage(admin, target, tier) |> errors()

  # ── helpers ───────────────────────────────────────────────────────────

  defp profile_out(%Profile{} = p, auth_method) do
    %{
      did: p.did,
      status: p.status,
      plan: p.plan,
      roles: p.roles,
      scopes: p.scopes |> MapSet.to_list() |> Enum.sort(),
      features: p.features |> MapSet.to_list() |> Enum.sort(),
      storage: p.storage,
      session_policy: p.policy,
      quota_bytes: to_string(p.quota_bytes),
      used_bytes: to_string(p.used_bytes),
      used_percent: if(p.quota_bytes > 0, do: Float.round(p.used_bytes * 100 / p.quota_bytes, 2), else: 0.0),
      auth_method: auth_method && to_string(auth_method)
    }
  end

  defp key_out(row) do
    %{
      id: row.id,
      name: row.name,
      key_prefix: row.key_prefix,
      scopes: row.scopes,
      allowed_ips: row.allowed_ips || [],
      expires_at: iso(row.expires_at),
      last_used_at: iso(row.last_used_at),
      last_used_ip: row.last_used_ip,
      revoked_at: iso(row.revoked_at),
      created_at: iso(row.created_at)
    }
  end

  defp found({:ok, nil}), do: {:error, :account_not_registered}
  defp found(other), do: other

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso(%NaiveDateTime{} = n), do: NaiveDateTime.to_iso8601(n) <> "Z"
  defp iso(other), do: to_string(other)

  defp errors({:ok, _} = ok), do: ok
  defp errors({:error, reason}) when is_atom(reason), do: {:error, Atom.to_string(reason)}
  defp errors({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp errors({:error, %Postgrex.Error{} = e}), do: {:error, "database_error: " <> Exception.message(e)}
  defp errors({:error, reason}), do: {:error, inspect(reason)}
end
