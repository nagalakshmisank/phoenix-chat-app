defmodule Przma.Authz.Repo.Migrations.SeedPrzmaAuthz do
  @moduledoc """
  Starting data: roles, plans (tier1 = free, tier2 = premium/business),
  scopes, role -> scope matrix, features, plan -> feature matrix and
  session policies.

  ON CONFLICT DO NOTHING everywhere: rows the admin team already
  inserted (or later edited in Supabase Studio) are never overwritten.
  Quotas and session numbers are proposals until the mentor confirms.
  """
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO przma_authz.roles (code, name, description) VALUES
      ('basic_user',      'Basic PRZMA user',              'Every new user on the free plan'),
      ('privileged_user', 'Privileged user',               'Paid individual user'),
      ('business_user',   'Business user',                 'Business account'),
      ('platform_admin',  'Platform admin (Olimyam staff)', 'Manages plans, suspensions and security')
    ON CONFLICT (code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.plans (code, name, storage_tier, storage_quota_bytes, default_role) VALUES
      ('free',     'Free',     1,   5368709120, 'basic_user'),
      ('premium',  'Premium',  2,  53687091200, 'privileged_user'),
      ('business', 'Business', 2, 214748364800, 'business_user')
    ON CONFLICT (code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.scopes (code, service, description) VALUES
      ('auth:register',     'auth',     'Complete registration (any valid Keycloak token)'),
      ('profile:rw',        'profile',  'Read and update own profile, own access and sessions'),
      ('calendar:read',     'calendar', 'Read calendars and events'),
      ('calendar:rw',       'calendar', 'Create, edit and share calendars and events'),
      ('calendar:plus',     'calendar', 'Date polls and invite links'),
      ('calendar:business', 'calendar', 'Working hours, free/busy, common slots'),
      ('calendar:booking',  'calendar', 'Public booking pages'),
      ('files:rw',          'files',    'Upload and read files'),
      ('social:rw',         'social',   'Chat, circles, contacts, notifications'),
      ('search:read',       'search',   'Search own content'),
      ('keys:manage',       'keys',     'Create and revoke access keys'),
      ('admin:*',           'admin',    'Platform administration')
    ON CONFLICT (code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.role_scopes (role_code, scope_code)
    SELECT r.role_code, r.scope_code FROM (VALUES
      ('basic_user', 'profile:rw'), ('basic_user', 'calendar:read'), ('basic_user', 'calendar:rw'),
      ('basic_user', 'files:rw'), ('basic_user', 'social:rw'), ('basic_user', 'search:read'),

      ('privileged_user', 'profile:rw'), ('privileged_user', 'calendar:read'), ('privileged_user', 'calendar:rw'),
      ('privileged_user', 'calendar:plus'), ('privileged_user', 'files:rw'), ('privileged_user', 'social:rw'),
      ('privileged_user', 'search:read'), ('privileged_user', 'keys:manage'),

      ('business_user', 'profile:rw'), ('business_user', 'calendar:read'), ('business_user', 'calendar:rw'),
      ('business_user', 'calendar:plus'), ('business_user', 'calendar:business'), ('business_user', 'calendar:booking'),
      ('business_user', 'files:rw'), ('business_user', 'social:rw'), ('business_user', 'search:read'),
      ('business_user', 'keys:manage'),

      ('platform_admin', 'profile:rw'), ('platform_admin', 'calendar:read'), ('platform_admin', 'calendar:rw'),
      ('platform_admin', 'calendar:plus'), ('platform_admin', 'calendar:business'), ('platform_admin', 'calendar:booking'),
      ('platform_admin', 'files:rw'), ('platform_admin', 'social:rw'), ('platform_admin', 'search:read'),
      ('platform_admin', 'admin:*')
    ) AS r(role_code, scope_code)
    ON CONFLICT (role_code, scope_code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.features (code, service, description) VALUES
      ('calendar.basic',       'calendar', 'Calendars, events, sharing, reminders, notes'),
      ('calendar.polls',       'calendar', 'Date polls'),
      ('calendar.share_links', 'calendar', 'Invite links for non-PRZMA users'),
      ('calendar.business',    'calendar', 'Working hours and free/busy'),
      ('calendar.booking',     'calendar', 'Public booking page'),
      ('files.upload',         'files',    'File upload'),
      ('social.chat',          'social',   'Chat and circles'),
      ('keys.access_keys',     'keys',     'Access keys')
    ON CONFLICT (code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.plan_features (plan_code, feature_code)
    SELECT p.plan_code, p.feature_code FROM (VALUES
      ('free', 'calendar.basic'), ('free', 'files.upload'), ('free', 'social.chat'),
      ('premium', 'calendar.basic'), ('premium', 'calendar.polls'), ('premium', 'calendar.share_links'),
      ('premium', 'files.upload'), ('premium', 'social.chat'), ('premium', 'keys.access_keys'),
      ('business', 'calendar.basic'), ('business', 'calendar.polls'), ('business', 'calendar.share_links'),
      ('business', 'calendar.business'), ('business', 'calendar.booking'),
      ('business', 'files.upload'), ('business', 'social.chat'), ('business', 'keys.access_keys')
    ) AS p(plan_code, feature_code)
    ON CONFLICT (plan_code, feature_code) DO NOTHING
    """

    execute """
    INSERT INTO przma_authz.session_policies
      (role_code, max_session_seconds, idle_timeout_seconds, max_devices, max_key_days) VALUES
      ('basic_user',       604800, 86400,  3,   0),
      ('privileged_user', 1209600, 172800, 5,  90),
      ('business_user',   2592000, 28800, 10, 180),
      ('platform_admin',    43200, 1800,   2,   0)
    ON CONFLICT (role_code) DO NOTHING
    """
  end

  def down, do: :ok
end
