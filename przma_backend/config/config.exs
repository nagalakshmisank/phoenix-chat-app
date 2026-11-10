import Config

config :przma, PRZMAWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: PRZMAWeb.ErrorJSON], layout: false],
  pubsub_server: Przma.PubSub,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4200")],
  server: true

config :przma, :keycloak,
  url: System.get_env("KEYCLOAK_URL", "http://172.235.18.126:8180"),
  realm: System.get_env("KEYCLOAK_REALM", "przma")

config :przma, :vault_nif_adapter, Przma.Vault.LanceLinodeAdapter

# Ecto: the commons Postgres database (public-file CAS copy). Connection
# settings are in runtime.exs; migrations live in priv/commons_cas/migrations.
#   mix ecto.migrate -r Przma.CommonsCas.Repo
config :przma, ecto_repos: [Przma.CommonsCas.Repo, Przma.Authz.Repo]
config :przma, Przma.CommonsCas.Repo, priv: "priv/commons_cas"

# Ecto: authorisation scope tables (schema przma_authz). Connection in
# runtime.exs; migrations in priv/authz/migrations:
#   mix ecto.migrate -r Przma.Authz.Repo
# Every connection runs SET search_path TO przma_authz, so this repo's own
# schema_migrations table is created inside przma_authz too (nothing goes
# into public or Supabase's schemas). The schema must exist first:
#   psql "$AUTHZ_DATABASE_URL" -c "create schema if not exists przma_authz;"
config :przma, Przma.Authz.Repo,
  priv: "priv/authz",
  after_connect: {Postgrex, :query!, ["SET search_path TO przma_authz", []]}

# Authorisation scope settings (runtime.exs reads the env vars).
config :przma, :authz,
  # "enforce" | "log" | "off" — see Przma.Authz
  mode: "enforce",
  # access profile / session / key / location cache
  profile_ttl_ms: 60_000,
  # Keycloak tier role -> plan for new users (tier3 is treated as 2 for now)
  tier_plans: %{1 => "free", 2 => "premium"},
  # denied calls with one access key in 10 minutes before it is revoked
  key_abuse_threshold: 50

# {namespace, table} pairs stored in the LanceDB DOC STORE (see
# Przma.Vault.BackendRouter + Przma.Vault.LanceDocAdapter). Each pair is one
# .lance table per user and space, in S3:
#   vault/profile   -> {base}/did_…/vault/private/profile.lance
#   files/index     -> {base}/did_…/files/{private|personal|public}/index.lance
#   files/cas_meta  -> {base}/did_…/files/cas/cas_meta.lance
# Everything NOT listed here (e.g. public/_meta) stays on LanceLinodeAdapter.
config :przma, :doc_store_tables, [
  {"vault", "profile"},
  {"files", "index"},
  {"files", "cas_meta"},
  # chat service (inbox / outbox / chat list)
  {"chat", "inbox"},
  {"chat", "outbox"},
  {"chat", "threads"},
  # circle service
  {"circle", "circles"},
  {"circle", "members"},
  {"circle", "memberships"},
  {"circle", "pins"},
  {"circle", "followers"},
  {"circle", "invites"},
  {"circle", "index"},
  # contacts, follows, shared account directory, notification settings
  {"social", "contacts"},
  {"social", "contact_types"},
  {"social", "following"},
  {"social", "accounts"},
  {"social", "notification_settings"},
  # calendar service (lib/przma/calendar) — per-user tables
  {"calendar", "calendars"},
  {"calendar", "events"},
  {"calendar", "shares"},
  {"calendar", "invites"},
  {"calendar", "subscriptions"},
  {"calendar", "invited"},
  {"calendar", "private_notes"},
  # calendar service — shared tables of did:przma-system:calendar
  {"calendar", "index"},
  {"calendar", "circle_calendars"},
  {"calendar", "reminders"},
  {"calendar", "scheduler"},
  {"calendar", "holidays"}
]

# Calendar service defaults (lib/przma/calendar).
config :przma, :calendar,
  default_timezone: "Asia/Kolkata",
  default_region: "IN_TN",
  # minutes before the start, used when createEvent sends no reminders
  default_reminders: [15]

# Reminder scheduler: run on ONE node only.
config :przma, Przma.Calendar.ReminderScheduler,
  enabled: true,
  interval_ms: 60_000,
  import_holidays_on_boot: false

config :przma, :doc_store_adapter, Przma.Vault.LanceDocAdapter

config :logger, :console, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
