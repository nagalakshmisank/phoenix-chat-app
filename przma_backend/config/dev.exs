import Config

config :przma, PRZMAWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4200")],
  check_origin: false,
  debug_errors: true,
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "dev_only_secret_key_base_at_least_64_bytes_long_padding_padding_pad",
  watchers: []

config :logger, :console, format: "[$level] $message\n"
