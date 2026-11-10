defmodule Przma.Authz.Admin do
  @moduledoc """
  Platform-admin actions (scope `admin:*`). Every change writes an
  audit_log row and drops the user's cached profile, so it takes effect
  within one request on this node.

    * set_plan/3          free / premium / business: role, quota and plan features;
                          moving to a higher storage tier copies the user's data
                          to the new bucket in the background
    * set_status/4        active / suspended (suspended users get account_suspended)
    * revoke_sessions/3   logs the user out of every device
    * grant_feature/5     a trial or manual feature grant with an end date
    * migrate_storage/3   move a legacy tier2 user out of perkeep
  """

  require Logger
  alias Przma.Authz.{Cache, Db, KeycloakAdmin, Repo, Sessions, Telemetry}
  alias Przma.Storage.Location

  def account(did) do
    with {:ok, profile} <- Przma.Authz.Profile.load(did) do
      case profile do
        nil -> {:error, :not_found}
        p -> {:ok, p}
      end
    end
  end

  def security_events(did, limit) do
    Db.all(
      """
      SELECT id, did, access_key_id::text AS access_key_id, event_type, severity, host(ip) AS ip,
             details, action_taken, created_at
        FROM przma_authz.security_events
       WHERE ($1::text IS NULL OR did = $1)
       ORDER BY created_at DESC LIMIT $2
      """,
      [did, min(limit || 50, 500)]
    )
  end

  @doc "Changes a user's plan (and with it role, quota, features, storage tier)."
  def set_plan(admin_did, did, plan_code) do
    with {:ok, %{} = old} <- one_account(did),
         {:ok, %{} = plan} <-
           Db.one("SELECT code, default_role, storage_quota_bytes, storage_tier FROM przma_authz.plans WHERE code = $1 AND active", [plan_code])
           |> not_found(:unknown_plan) do
      tx =
        Repo.transaction(fn ->
          Db.all!("UPDATE przma_authz.accounts SET plan_code = $2, updated_at = now() WHERE did = $1 RETURNING did", [did, plan.code])

          # Replace the plan role; keep any other role (e.g. platform_admin).
          Db.all!(
            """
            DELETE FROM przma_authz.user_roles
             WHERE did = $1 AND role_code IN (SELECT default_role FROM przma_authz.plans) AND role_code <> $2
            RETURNING did
            """,
            [did, plan.default_role]
          )

          Db.all!(
            """
            INSERT INTO przma_authz.user_roles (did, role_code, granted_by) VALUES ($1, $2, $3)
            ON CONFLICT (did, role_code) DO NOTHING RETURNING did
            """,
            [did, plan.default_role, admin_did]
          )

          Db.all!("UPDATE przma_authz.storage_usage SET quota_bytes = $2, updated_at = now() WHERE did = $1 RETURNING did", [did, plan.storage_quota_bytes])

          # The personal workspace follows the plan; its 'plan' entitlements are re-copied.
          Db.all!("UPDATE przma_authz.workspaces SET plan_code = $2 WHERE owner_did = $1 AND kind = 'personal' RETURNING id", [did, plan.code])

          Db.all!(
            """
            DELETE FROM przma_authz.entitlements
             WHERE source = 'plan'
               AND workspace_id IN (SELECT id FROM przma_authz.workspaces WHERE owner_did = $1 AND kind = 'personal')
            RETURNING id
            """,
            [did]
          )

          Db.all!(
            """
            INSERT INTO przma_authz.entitlements (workspace_id, feature_code, source, granted_by)
            SELECT w.id, pf.feature_code, 'plan', $3
              FROM przma_authz.workspaces w
              JOIN przma_authz.plan_features pf ON pf.plan_code = $2
             WHERE w.owner_did = $1 AND w.kind = 'personal'
            RETURNING id
            """,
            [did, plan.code, admin_did]
          )

          :ok =
            Telemetry.audit_now(%{
              actor: admin_did,
              action: "plan.changed",
              target_type: "account",
              target_id: did,
              before: %{plan: old.plan_code},
              after: %{plan: plan.code, role: plan.default_role, quota_bytes: plan.storage_quota_bytes}
            })

          :ok
        end)

      with {:ok, :ok} <- tx do
        Cache.invalidate(did)
        KeycloakAdmin.set_tier_async(Db.uuid_text(old.keycloak_user_id), plan.storage_tier)
        storage = maybe_move_storage(admin_did, did, plan.storage_tier, Db.uuid_text(old.keycloak_user_id))
        {:ok, %{did: did, plan: plan.code, role: plan.default_role, storage: storage}}
      end
    end
  end

  @doc "active | suspended"
  def set_status(admin_did, did, status, reason) when status in ["active", "suspended"] do
    with {:ok, %{} = old} <- one_account(did),
         :ok <- Db.exec("UPDATE przma_authz.accounts SET status = $2, updated_at = now() WHERE did = $1", [did, status]) do
      if status == "suspended", do: Sessions.revoke_all(did, "account_suspended")
      Cache.invalidate(did)

      Telemetry.audit(%{
        actor: admin_did,
        action: "account.status_changed",
        target_type: "account",
        target_id: did,
        before: %{status: old.status},
        after: %{status: status, reason: reason}
      })

      {:ok, %{did: did, status: status}}
    end
  end

  def set_status(_admin, _did, _status, _reason), do: {:error, :invalid_status}

  def revoke_sessions(admin_did, did, reason) do
    with {:ok, n} <- Sessions.revoke_all(did, reason || "admin") do
      Telemetry.audit(%{actor: admin_did, action: "sessions.revoked", target_type: "account", target_id: did, after: %{count: n, reason: reason}})
      {:ok, n}
    end
  end

  @doc "A trial or manual feature on the user's personal workspace, optionally until `days` from now."
  def grant_feature(admin_did, did, feature, source, days) when source in ["trial", "manual"] do
    result =
      Db.one(
        """
        INSERT INTO przma_authz.entitlements (workspace_id, feature_code, source, valid_until, granted_by)
        SELECT w.id, $2, $3, CASE WHEN $4::int IS NULL THEN NULL ELSE now() + make_interval(days => $4::int) END, $5
          FROM przma_authz.workspaces w WHERE w.owner_did = $1 AND w.kind = 'personal'
        ON CONFLICT (workspace_id, feature_code, source)
          DO UPDATE SET valid_from = now(), valid_until = EXCLUDED.valid_until, granted_by = EXCLUDED.granted_by
        RETURNING feature_code, source, valid_until
        """,
        [did, feature, source, days, admin_did]
      )

    case result do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, row} ->
        Cache.invalidate(did)
        Telemetry.audit(%{actor: admin_did, action: "feature.granted", target_type: "account", target_id: did, after: %{feature: feature, source: source, days: days}})
        {:ok, row}

      {:error, _} = err ->
        err
    end
  end

  def grant_feature(_a, _d, _f, _s, _days), do: {:error, :invalid_source}

  @doc "Moves a user's data to the bucket of `tier` (runs in the background)."
  def migrate_storage(admin_did, did, tier) when tier in [1, 2] do
    with {:ok, %{} = acc} <- one_account(did) do
      start_migration(admin_did, did, tier, Db.uuid_text(acc.keycloak_user_id))
      {:ok, "started"}
    end
  end

  def migrate_storage(_a, _d, _t), do: {:error, :unsupported_tier}

  # ── helpers ───────────────────────────────────────────────────────────

  # Only upgrades move data automatically (tier1 -> tier2). A downgrade
  # keeps the user's own bucket until an admin decides.
  defp maybe_move_storage(admin_did, did, new_tier, sub) do
    case Location.location(did) do
      %{storage_tier: 1} when new_tier == 2 ->
        start_migration(admin_did, did, 2, sub)
        "migrating to own bucket"

      %{storage_tier: t} ->
        "unchanged (tier #{t})"

      _ ->
        "no storage row"
    end
  end

  defp start_migration(admin_did, did, tier, sub) do
    Task.Supervisor.start_child(Przma.Authz.TaskSupervisor, fn ->
      case Location.migrate(did, tier, sub, admin_did) do
        {:ok, info} -> Logger.info("Authz: storage of #{did} moved: #{inspect(info)}")
        {:error, reason} -> Logger.error("Authz: storage move of #{did} failed: #{inspect(reason)}")
      end
    end)
  end

  defp one_account(did) do
    Db.one("SELECT did, status, plan_code, keycloak_user_id FROM przma_authz.accounts WHERE did = $1", [did])
    |> not_found(:not_found)
  end

  defp not_found({:ok, nil}, code), do: {:error, code}
  defp not_found(other, _code), do: other
end
