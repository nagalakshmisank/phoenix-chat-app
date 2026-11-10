defmodule Przma.Authz.Registration do
  @moduledoc """
  First step of `completeRegistration`: creates the user's rows in the
  central tables, in ONE Postgres transaction, BEFORE any LanceDB data
  is written (so the data goes to the right bucket from the start).

      accounts           plan from the Keycloak tier role (tier1 -> free, tier2 -> premium)
      user_roles         the plan's default role (basic_user / privileged_user)
      workspaces         personal workspace
      workspace_members  user = owner
      entitlements       the plan's features (source 'plan')
      storage_locations  tier1: s3://perkeep (ready) · tier2: s3://przma-<uuid> (provisioning)
      storage_usage      0 bytes used, quota from the plan
      audit_log          user.registered

  Then (outside the transaction) the tier2 bucket is created and the
  row marked ready. The account stays `pending_setup` until
  Przma.Vault.Registration has written the profile and default calendar,
  then activate/1 sets it `active`.

  Safe to repeat: an existing account is returned unchanged; a failed
  bucket creation is retried on the next call.

  Users who already have data in perkeep (registered before this
  release) keep using perkeep even when their token says tier2, so
  nothing is lost; an admin moves them later with adminMigrateStorage.
  """

  require Logger
  alias Przma.Authz.{Cache, Db, Repo, Telemetry}
  alias Przma.Storage.Location

  @type identity :: %{
          required(:did) => String.t(),
          required(:tenant_uuid) => String.t(),
          optional(:storage_tier) => integer(),
          optional(:token_claims) => map(),
          optional(:ip) => term()
        }

  @doc "Creates (or finds) the account. Returns {:ok, %{did, status, plan, storage}}."
  @spec ensure_account(identity()) :: {:ok, map()} | {:error, term()}
  def ensure_account(%{did: did, tenant_uuid: sub} = identity) when is_binary(sub) do
    case Db.one("SELECT did, status, plan_code FROM przma_authz.accounts WHERE did = $1", [did]) do
      {:ok, nil} -> create(identity)
      {:ok, account} -> finish_storage(account)
      {:error, _} = err -> err
    end
  end

  def ensure_account(_), do: {:error, :missing_keycloak_identity}

  @doc "pending_setup -> active, after the LanceDB setup succeeded."
  def activate(did) do
    result =
      Db.exec(
        "UPDATE przma_authz.accounts SET status = 'active', updated_at = now() WHERE did = $1 AND status = 'pending_setup'",
        [did]
      )

    Cache.invalidate(did)
    result
  end

  # ── create ────────────────────────────────────────────────────────────

  defp create(%{did: did, tenant_uuid: sub} = identity) do
    claims = identity[:token_claims] || %{}
    tier = supported_tier(identity[:storage_tier] || 1, did)
    plan_code = plan_for_tier(tier)

    with {:ok, storage} <- storage_plan(did, tier, sub) do
      tx =
        Repo.transaction(fn ->
          plan =
            Db.one!("SELECT code, default_role, storage_quota_bytes FROM przma_authz.plans WHERE code = $1", [plan_code]) ||
              Repo.rollback({:plan_missing, plan_code})

          username = claims["preferred_username"] || String.replace_prefix(did, "did:przma:", "")

          Db.one!(
            """
            INSERT INTO przma_authz.accounts (did, keycloak_user_id, username, email, status, plan_code)
            VALUES ($1, $2, $3, $4, 'pending_setup', $5)
            RETURNING did
            """,
            [did, Db.uuid(sub), username, claims["email"], plan_code]
          )

          Db.one!(
            "INSERT INTO przma_authz.user_roles (did, role_code, granted_by) VALUES ($1, $2, 'system:registration') RETURNING did",
            [did, plan.default_role]
          )

          %{id: ws_id} =
            Db.one!(
              """
              INSERT INTO przma_authz.workspaces (owner_did, kind, name, plan_code)
              VALUES ($1, 'personal', $2, $3) RETURNING id
              """,
              [did, username <> " personal", plan_code]
            )

          Db.all!(
            "INSERT INTO przma_authz.workspace_members (workspace_id, did, role) VALUES ($1, $2, 'owner') RETURNING did",
            [ws_id, did]
          )

          Db.all!(
            """
            INSERT INTO przma_authz.entitlements (workspace_id, feature_code, source, granted_by)
            SELECT $1, feature_code, 'plan', 'system:registration'
              FROM przma_authz.plan_features WHERE plan_code = $2
            RETURNING id
            """,
            [ws_id, plan_code]
          )

          Db.all!(
            """
            INSERT INTO przma_authz.storage_locations (did, storage_tier, bucket, base_path, status)
            VALUES ($1, $2, $3, $4, $5) RETURNING did
            """,
            [did, storage.tier, storage.bucket, storage.base_path, storage.status]
          )

          Db.all!(
            "INSERT INTO przma_authz.storage_usage (did, quota_bytes) VALUES ($1, $2) RETURNING did",
            [did, plan.storage_quota_bytes]
          )

          case Telemetry.audit_now(%{
                 actor: "system:registration",
                 action: "user.registered",
                 target_type: "account",
                 target_id: did,
                 after: %{
                   plan: plan_code,
                   role: plan.default_role,
                   storage_tier: storage.tier,
                   bucket: storage.bucket,
                   keycloak_tier: identity[:storage_tier]
                 },
                 ip: identity[:ip]
               }) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end

          %{did: did, status: "pending_setup", plan_code: plan_code}
        end)

      case tx do
        {:ok, account} ->
          Cache.invalidate(did)
          finish_storage(account)

        {:error, reason} ->
          # Two first calls at the same moment: the loser sees the winner's row.
          case Db.one("SELECT did, status, plan_code FROM przma_authz.accounts WHERE did = $1", [did]) do
            {:ok, %{} = account} -> finish_storage(account)
            _ -> {:error, {:authz_registration_failed, reason}}
          end
      end
    end
  end

  # Tier2 bucket: create it now (or retry a failed attempt).
  defp finish_storage(account) do
    case Location.provision(account.did) do
      :ok ->
        {:ok, Map.put(account, :storage, Location.location(account.did))}

      {:error, :no_storage_location} ->
        {:ok, Map.put(account, :storage, nil)}

      {:error, _} = err ->
        err
    end
  end

  # Tier1 -> perkeep. Tier2 -> own bucket, unless the user already has data
  # in perkeep (registered before this release): then stay on perkeep.
  defp storage_plan(_did, 1, sub), do: {:ok, Location.plan_for(1, sub)}

  defp storage_plan(did, 2, sub) do
    case Location.has_data?(Location.default_bucket(), did) do
      false ->
        {:ok, Location.plan_for(2, sub)}

      true ->
        Logger.warning("Authz: #{did} is tier2 but already has data in perkeep; keeping perkeep until migrated")

        Telemetry.audit(%{
          actor: "system:registration",
          action: "storage.migration_needed",
          target_type: "account",
          target_id: did,
          after: %{from_bucket: Location.default_bucket(), to_bucket: Location.tier2_bucket(sub)}
        })

        {:ok, Map.put(Location.plan_for(1, sub), :tier, 2)}

      {:error, reason} ->
        {:error, {:storage_check_failed, reason}}
    end
  end

  defp supported_tier(3, did) do
    Logger.warning("Authz: #{did} has tier3-user, which is not supported yet; using tier 2")
    2
  end

  defp supported_tier(t, _did) when t in [1, 2], do: t
  defp supported_tier(_, _did), do: 1

  defp plan_for_tier(tier) do
    plans = Keyword.get(Application.get_env(:przma, :authz, []), :tier_plans, %{1 => "free", 2 => "premium"})
    Map.fetch!(plans, tier)
  end
end
