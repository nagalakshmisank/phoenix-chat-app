defmodule PRZMAWeb.Graphql.Types.AuthzTypes do
  @moduledoc """
  GraphQL API for authorisation scope:

    queries    myAccess, mySessions, myAccessKeys,
               adminAccount, adminSecurityEvents            (admin:*)
    mutations  revokeMySession, createAccessKey, revokeAccessKey,
               adminSetPlan, adminSetAccountStatus, adminRevokeSessions,
               adminGrantFeature, adminMigrateStorage       (admin:*)

  Byte counts are strings (they pass GraphQL's 32-bit Int limit).
  """
  use Absinthe.Schema.Notation

  alias PRZMAWeb.Graphql.Resolvers.AuthzResolver

  object :storage_info do
    field :tier, :integer
    field :bucket, :string
    field :base_path, :string
    field :status, :string
  end

  object :session_policy do
    field :max_session_seconds, :integer
    field :idle_timeout_seconds, :integer
    field :max_devices, :integer
    field :max_key_days, :integer
  end

  object :access_profile do
    field :did, :string
    field :status, :string
    field :plan, :string
    field :roles, list_of(:string)
    field :scopes, list_of(:string)
    field :features, list_of(:string)
    field :storage, :storage_info
    field :session_policy, :session_policy
    field :quota_bytes, :string
    field :used_bytes, :string
    field :used_percent, :float
    field :auth_method, :string
  end

  object :session_info do
    field :sid, :string
    field :device, :string
    field :ip, :string
    field :user_agent, :string
    field :auth_time, :string
    field :last_seen_at, :string
    field :current, :boolean
  end

  object :access_key_info do
    field :id, :string
    field :name, :string
    field :key_prefix, :string
    field :scopes, list_of(:string)
    field :allowed_ips, list_of(:string)
    field :expires_at, :string
    field :last_used_at, :string
    field :last_used_ip, :string
    field :revoked_at, :string
    field :created_at, :string
  end

  object :access_key_created do
    @desc "The full key. Shown only once — store it safely."
    field :key, :string
    field :access_key, :access_key_info
  end

  object :security_event_info do
    field :id, :string
    field :did, :string
    field :access_key_id, :string
    field :event_type, :string
    field :severity, :string
    field :ip, :string
    @desc "JSON text"
    field :details, :string
    field :action_taken, :string
    field :created_at, :string
  end

  object :plan_change_result do
    field :did, :string
    field :plan, :string
    field :role, :string
    field :storage, :string
  end

  object :account_status_result do
    field :did, :string
    field :status, :string
  end

  object :feature_grant do
    field :feature_code, :string
    field :source, :string
    field :valid_until, :string
  end

  object :authz_queries do
    @desc "My plan, roles, scopes, features, storage location and usage."
    field :my_access, :access_profile do
      resolve &AuthzResolver.my_access/2
    end

    @desc "My active logins (one per device / Keycloak session)."
    field :my_sessions, list_of(:session_info) do
      resolve &AuthzResolver.my_sessions/2
    end

    field :my_access_keys, list_of(:access_key_info) do
      resolve &AuthzResolver.my_access_keys/2
    end

    @desc "Admin: one user's access profile."
    field :admin_account, :access_profile do
      arg :did, non_null(:string)
      resolve &AuthzResolver.admin_account/2
    end

    @desc "Admin: latest security events (all users, or one did)."
    field :admin_security_events, list_of(:security_event_info) do
      arg :did, :string
      arg :limit, :integer
      resolve &AuthzResolver.admin_security_events/2
    end
  end

  object :authz_mutations do
    @desc "Log out one of my other devices."
    field :revoke_my_session, :boolean do
      arg :sid, non_null(:string)
      resolve &AuthzResolver.revoke_my_session/2
    end

    @desc "Creates an access key (X-API-Key). scopes must be ones I have; days up to my role's limit."
    field :create_access_key, :access_key_created do
      arg :name, non_null(:string)
      arg :scopes, non_null(list_of(non_null(:string)))
      arg :days, :integer
      arg :allowed_ips, list_of(non_null(:string))
      resolve &AuthzResolver.create_access_key/2
    end

    field :revoke_access_key, :boolean do
      arg :id, non_null(:string)
      resolve &AuthzResolver.revoke_access_key/2
    end

    @desc "Admin: plan = free | premium | business."
    field :admin_set_plan, :plan_change_result do
      arg :did, non_null(:string)
      arg :plan, non_null(:string)
      resolve &AuthzResolver.admin_set_plan/2
    end

    @desc "Admin: status = active | suspended."
    field :admin_set_account_status, :account_status_result do
      arg :did, non_null(:string)
      arg :status, non_null(:string)
      arg :reason, :string
      resolve &AuthzResolver.admin_set_account_status/2
    end

    @desc "Admin: log the user out of every device. Returns how many sessions were ended."
    field :admin_revoke_sessions, :integer do
      arg :did, non_null(:string)
      arg :reason, :string
      resolve &AuthzResolver.admin_revoke_sessions/2
    end

    @desc "Admin: source = trial | manual; days = null for no end date."
    field :admin_grant_feature, :feature_grant do
      arg :did, non_null(:string)
      arg :feature, non_null(:string)
      arg :source, non_null(:string)
      arg :days, :integer
      resolve &AuthzResolver.admin_grant_feature/2
    end

    @desc "Admin: copy the user's data to the bucket of tier 1 or 2 (runs in the background)."
    field :admin_migrate_storage, :string do
      arg :did, non_null(:string)
      arg :tier, non_null(:integer)
      resolve &AuthzResolver.admin_migrate_storage/2
    end
  end
end
