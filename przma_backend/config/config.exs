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
  {"social", "notification_settings"}
]

config :przma, :doc_store_adapter, Przma.Vault.LanceDocAdapter

config :logger, :console, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
