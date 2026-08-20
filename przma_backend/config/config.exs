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

config :logger, :console, format: "$time $metadata[$level] $message\n"

import_config "#{config_env()}.exs"
