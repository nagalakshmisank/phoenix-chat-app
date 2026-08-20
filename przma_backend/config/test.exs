import Config

config :przma, PRZMAWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4202],
  secret_key_base:
    "test_only_secret_key_base_at_least_64_bytes_long_padding_padding_pad",
  server: false

config :logger, level: :warning
