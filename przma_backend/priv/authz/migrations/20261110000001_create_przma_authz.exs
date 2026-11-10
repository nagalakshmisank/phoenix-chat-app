defmodule Przma.Authz.Repo.Migrations.CreatePrzmaAuthz do
  @moduledoc """
  The 20 centralised authorisation tables, in schema `przma_authz`.

  Every statement uses IF NOT EXISTS, so this migration is safe to run
  even if the admin team already created the tables with the SQL script
  from the "PRZMA Authorisation — Postgres Tables" doc.
  """
  use Ecto.Migration

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS przma_authz"

    # 1. Roles and plans
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.roles (
      code         text PRIMARY KEY,
      name         text NOT NULL,
      description  text
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.plans (
      code                text PRIMARY KEY,
      name                text NOT NULL,
      storage_tier        smallint NOT NULL CHECK (storage_tier IN (1, 2, 3)),
      storage_quota_bytes bigint NOT NULL,
      default_role        text NOT NULL REFERENCES przma_authz.roles(code),
      active              boolean NOT NULL DEFAULT true
    )
    """

    # 2. Users
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.accounts (
      did               text PRIMARY KEY,
      keycloak_user_id  uuid NOT NULL UNIQUE,
      username          text NOT NULL UNIQUE,
      email             text,
      status            text NOT NULL DEFAULT 'pending_setup'
                        CHECK (status IN ('pending_setup', 'active', 'suspended', 'deleted')),
      plan_code         text NOT NULL REFERENCES przma_authz.plans(code),
      created_at        timestamptz NOT NULL DEFAULT now(),
      updated_at        timestamptz NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.user_roles (
      did         text NOT NULL REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      role_code   text NOT NULL REFERENCES przma_authz.roles(code),
      granted_by  text,
      granted_at  timestamptz NOT NULL DEFAULT now(),
      expires_at  timestamptz,
      PRIMARY KEY (did, role_code)
    )
    """

    # 3. Permissions and feature gating
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.scopes (
      code         text PRIMARY KEY,
      service      text NOT NULL,
      description  text
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.role_scopes (
      role_code   text NOT NULL REFERENCES przma_authz.roles(code) ON DELETE CASCADE,
      scope_code  text NOT NULL REFERENCES przma_authz.scopes(code) ON DELETE CASCADE,
      PRIMARY KEY (role_code, scope_code)
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.features (
      code         text PRIMARY KEY,
      service      text NOT NULL,
      description  text
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.plan_features (
      plan_code     text NOT NULL REFERENCES przma_authz.plans(code) ON DELETE CASCADE,
      feature_code  text NOT NULL REFERENCES przma_authz.features(code) ON DELETE CASCADE,
      limit_value   bigint,
      PRIMARY KEY (plan_code, feature_code)
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.api_endpoints (
      id                  bigserial PRIMARY KEY,
      kind                text NOT NULL CHECK (kind IN ('graphql_query', 'graphql_mutation', 'rest')),
      name                text NOT NULL,
      scope_code          text NOT NULL REFERENCES przma_authz.scopes(code),
      feature_code        text REFERENCES przma_authz.features(code),
      rate_limit_per_min  integer,
      active              boolean NOT NULL DEFAULT true,
      created_at          timestamptz NOT NULL DEFAULT now(),
      UNIQUE (kind, name)
    )
    """

    # 4. Workspaces
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.workspaces (
      id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      owner_did   text NOT NULL REFERENCES przma_authz.accounts(did),
      kind        text NOT NULL CHECK (kind IN ('personal', 'family', 'business')),
      name        text NOT NULL,
      plan_code   text NOT NULL REFERENCES przma_authz.plans(code),
      status      text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deleted')),
      created_at  timestamptz NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.workspace_members (
      workspace_id  uuid NOT NULL REFERENCES przma_authz.workspaces(id) ON DELETE CASCADE,
      did           text NOT NULL REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      role          text NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'guest')),
      is_minor      boolean NOT NULL DEFAULT false,
      joined_at     timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (workspace_id, did)
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.entitlements (
      id            bigserial PRIMARY KEY,
      workspace_id  uuid NOT NULL REFERENCES przma_authz.workspaces(id) ON DELETE CASCADE,
      feature_code  text NOT NULL REFERENCES przma_authz.features(code),
      source        text NOT NULL CHECK (source IN ('plan', 'trial', 'manual')),
      valid_from    timestamptz NOT NULL DEFAULT now(),
      valid_until   timestamptz,
      granted_by    text,
      UNIQUE (workspace_id, feature_code, source)
    )
    """

    # 5. Storage
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.storage_locations (
      did           text PRIMARY KEY REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      storage_tier  smallint NOT NULL CHECK (storage_tier IN (1, 2, 3)),
      provider      text NOT NULL DEFAULT 'linode',
      endpoint      text NOT NULL DEFAULT 'https://in-maa-1.linodeobjects.com',
      region        text NOT NULL DEFAULT 'in-maa-1',
      bucket        text NOT NULL,
      base_path     text NOT NULL,
      status        text NOT NULL DEFAULT 'provisioning'
                    CHECK (status IN ('provisioning', 'ready', 'migrating', 'failed')),
      created_at    timestamptz NOT NULL DEFAULT now(),
      updated_at    timestamptz NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.storage_usage (
      did          text PRIMARY KEY REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      quota_bytes  bigint NOT NULL,
      used_bytes   bigint NOT NULL DEFAULT 0,
      file_count   bigint NOT NULL DEFAULT 0,
      updated_at   timestamptz NOT NULL DEFAULT now()
    )
    """

    # 6. Sessions and access keys
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.session_policies (
      role_code             text PRIMARY KEY REFERENCES przma_authz.roles(code) ON DELETE CASCADE,
      max_session_seconds   integer NOT NULL,
      idle_timeout_seconds  integer NOT NULL,
      max_devices           integer NOT NULL,
      max_key_days          integer NOT NULL DEFAULT 0
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.sessions (
      sid             text PRIMARY KEY,
      did             text NOT NULL REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      device          text,
      ip              inet,
      user_agent      text,
      auth_time       timestamptz NOT NULL,
      created_at      timestamptz NOT NULL DEFAULT now(),
      last_seen_at    timestamptz NOT NULL DEFAULT now(),
      revoked_at      timestamptz,
      revoked_reason  text
    )
    """

    execute "CREATE INDEX IF NOT EXISTS sessions_did_idx ON przma_authz.sessions (did)"

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.access_keys (
      id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      did           text NOT NULL REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      name          text NOT NULL,
      key_prefix    text NOT NULL,
      key_hash      text NOT NULL UNIQUE,
      scopes        text[] NOT NULL,
      allowed_ips   cidr[],
      expires_at    timestamptz NOT NULL,
      last_used_at  timestamptz,
      last_used_ip  inet,
      revoked_at    timestamptz,
      created_at    timestamptz NOT NULL DEFAULT now()
    )
    """

    execute "CREATE INDEX IF NOT EXISTS access_keys_did_idx ON przma_authz.access_keys (did)"

    # 7. Security and telemetry
    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.security_events (
      id             bigserial PRIMARY KEY,
      did            text,
      access_key_id  uuid,
      event_type     text NOT NULL,
      severity       text NOT NULL CHECK (severity IN ('low', 'medium', 'high', 'critical')),
      ip             inet,
      details        jsonb,
      action_taken   text,
      created_at     timestamptz NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS security_events_did_time_idx
      ON przma_authz.security_events (did, created_at)
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.usage_daily (
      did            text NOT NULL REFERENCES przma_authz.accounts(did) ON DELETE CASCADE,
      day            date NOT NULL,
      service        text NOT NULL,
      api_calls      bigint NOT NULL DEFAULT 0,
      errors         bigint NOT NULL DEFAULT 0,
      bytes_written  bigint NOT NULL DEFAULT 0,
      bytes_read     bigint NOT NULL DEFAULT 0,
      PRIMARY KEY (did, day, service)
    )
    """

    execute """
    CREATE TABLE IF NOT EXISTS przma_authz.audit_log (
      id           bigserial PRIMARY KEY,
      actor_did    text,
      action       text NOT NULL,
      target_type  text,
      target_id    text,
      before       jsonb,
      after        jsonb,
      ip           inet,
      created_at   timestamptz NOT NULL DEFAULT now()
    )
    """

    execute """
    CREATE INDEX IF NOT EXISTS audit_log_target_idx
      ON przma_authz.audit_log (target_type, target_id)
    """
  end

  # Down is intentionally a no-op: these tables hold users' roles, plans,
  # sessions and audit history. Dropping them must be a manual,
  # reviewed decision by the admin team, never a side effect of a rollback.
  def down, do: :ok
end
