defmodule Przma.Authz.Profile do
  @moduledoc """
  A user's access profile: everything the guard needs to decide a call,
  built from the central tables and cached for 60 s (Przma.Authz.Cache).

      %Przma.Authz.Profile{
        did: "did:przma:priya", status: "active", plan: "free",
        roles: ["basic_user"], scopes: MapSet<["calendar:rw", …]>,
        features: MapSet<["calendar.basic", …]>,
        policy: %{max_session_seconds: 604800, idle_timeout_seconds: 86400,
                  max_devices: 3, max_key_days: 0},
        storage: %{tier: 1, bucket: "perkeep", base_path: "s3://perkeep", status: "ready"},
        quota_bytes: 5368709120, used_bytes: 20971520,
        keycloak_user_id: "b656d159-…"
      }
  """

  alias Przma.Authz.{Cache, Db}

  defstruct did: nil,
            status: nil,
            plan: nil,
            roles: [],
            scopes: MapSet.new(),
            features: MapSet.new(),
            policy: %{},
            storage: %{},
            quota_bytes: 0,
            used_bytes: 0,
            keycloak_user_id: nil,
            username: nil

  @type t :: %__MODULE__{}

  # When a user has several roles, the session policy of the first role
  # in this list wins (an admin always gets the strict admin policy).
  @policy_order ["platform_admin", "business_user", "privileged_user", "basic_user"]

  @default_policy %{
    max_session_seconds: 604_800,
    idle_timeout_seconds: 86_400,
    max_devices: 3,
    max_key_days: 0
  }

  @doc "Cached profile. {:ok, nil} when the user has no account row yet."
  @spec get(String.t()) :: {:ok, t() | nil} | {:error, term()}
  def get(did) when is_binary(did) do
    case Cache.get({:profile, did}) do
      {:ok, profile} ->
        {:ok, profile}

      :miss ->
        case load(did) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, profile} ->
            Cache.put({:profile, did}, profile)
            {:ok, profile}

          {:error, _} = err ->
            err
        end
    end
  end

  @doc "Profile straight from Postgres (no cache)."
  @spec load(String.t()) :: {:ok, t() | nil} | {:error, term()}
  def load(did) do
    with {:ok, account} <- account(did) do
      if account do
        with {:ok, roles} <- roles(did),
             {:ok, scopes} <- scopes(did),
             {:ok, features} <- features(did, account.plan_code),
             {:ok, policy} <- policy(roles) do
          {:ok,
           %__MODULE__{
             did: did,
             status: account.status,
             plan: account.plan_code,
             roles: roles,
             scopes: MapSet.new(scopes),
             features: MapSet.new(features),
             policy: policy,
             storage: %{
               tier: account.storage_tier,
               bucket: account.bucket,
               base_path: account.base_path,
               status: account.storage_status
             },
             quota_bytes: account.quota_bytes || 0,
             used_bytes: account.used_bytes || 0,
             keycloak_user_id: Db.uuid_text(account.keycloak_user_id),
             username: account.username
           }}
        end
      else
        {:ok, nil}
      end
    end
  end

  @doc "True when `needed` is granted by the scope set (rw implies read)."
  @spec has_scope?(MapSet.t() | [String.t()], String.t()) :: boolean()
  def has_scope?(scopes, needed) when is_list(scopes), do: has_scope?(MapSet.new(scopes), needed)

  def has_scope?(scopes, needed) do
    MapSet.member?(scopes, needed) or
      (String.ends_with?(needed, ":read") and
         MapSet.member?(scopes, String.replace_suffix(needed, ":read", ":rw")))
  end

  @doc "Scope -> service name, used for telemetry (\"calendar:rw\" -> \"calendar\")."
  def service_of(scope) when is_binary(scope), do: scope |> String.split(":") |> hd()
  def service_of(_), do: "other"

  # ── queries ───────────────────────────────────────────────────────────

  defp account(did) do
    Db.one(
      """
      SELECT a.did, a.status, a.plan_code, a.keycloak_user_id, a.username,
             sl.storage_tier, sl.bucket, sl.base_path, sl.status AS storage_status,
             su.quota_bytes, su.used_bytes
        FROM przma_authz.accounts a
        LEFT JOIN przma_authz.storage_locations sl ON sl.did = a.did
        LEFT JOIN przma_authz.storage_usage su ON su.did = a.did
       WHERE a.did = $1
      """,
      [did]
    )
  end

  defp roles(did) do
    with {:ok, rows} <-
           Db.all(
             """
             SELECT role_code FROM przma_authz.user_roles
              WHERE did = $1 AND (expires_at IS NULL OR expires_at > now())
              ORDER BY role_code
             """,
             [did]
           ) do
      {:ok, Enum.map(rows, & &1.role_code)}
    end
  end

  defp scopes(did) do
    with {:ok, rows} <-
           Db.all(
             """
             SELECT DISTINCT rs.scope_code
               FROM przma_authz.user_roles ur
               JOIN przma_authz.role_scopes rs ON rs.role_code = ur.role_code
              WHERE ur.did = $1 AND (ur.expires_at IS NULL OR ur.expires_at > now())
             """,
             [did]
           ) do
      {:ok, Enum.map(rows, & &1.scope_code)}
    end
  end

  # Plan features + any active entitlement (trial / manual grant / plan copy)
  # on a workspace the user owns or administers.
  defp features(did, plan) do
    with {:ok, rows} <-
           Db.all(
             """
             SELECT feature_code FROM przma_authz.plan_features WHERE plan_code = $2
             UNION
             SELECT e.feature_code
               FROM przma_authz.entitlements e
               JOIN przma_authz.workspace_members wm ON wm.workspace_id = e.workspace_id
               JOIN przma_authz.workspaces w ON w.id = e.workspace_id
              WHERE wm.did = $1 AND wm.role IN ('owner', 'admin') AND w.status = 'active'
                AND e.valid_from <= now() AND (e.valid_until IS NULL OR e.valid_until > now())
             """,
             [did, plan]
           ) do
      {:ok, Enum.map(rows, & &1.feature_code)}
    end
  end

  defp policy([]), do: {:ok, @default_policy}

  defp policy(roles) do
    with {:ok, rows} <-
           Db.all(
             """
             SELECT role_code, max_session_seconds, idle_timeout_seconds, max_devices, max_key_days
               FROM przma_authz.session_policies WHERE role_code = ANY($1)
             """,
             [roles]
           ) do
      by_role = Map.new(rows, &{&1.role_code, &1})

      chosen =
        Enum.find_value(@policy_order, fn r -> Map.get(by_role, r) end) ||
          List.first(rows)

      {:ok,
       if chosen do
         Map.take(chosen, [:max_session_seconds, :idle_timeout_seconds, :max_devices, :max_key_days])
       else
         @default_policy
       end}
    end
  end
end
