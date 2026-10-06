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
config :przma, ecto_repos: [Przma.CommonsCas.Repo]
config :przma, Przma.CommonsCas.Repo, priv: "priv/commons_cas"

# {namespace, table} pairs stored in CouchDB instead of Lance (see
# Przma.Vault.BackendRouter). Everything else stays on Lance.
#   vault/profile   -> vault:private:profile
#   files/index     -> files:{private|personal|public}:index:{file_id}
#   files/cas_meta  -> files:cas:cas_meta:{sha256}
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
  {"social", "notification_settings"}
]

# Tables that also get a read-only JSON copy (*.couch.json) in S3.
# Files and CAS documents are intentionally NOT mirrored.
config :przma, :s3_mirror_tables, [{"vault", "profile"}]
config :przma, :doc_store_adapter, Przma.Vault.DocStoreAdapter

config :logger, :console, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
