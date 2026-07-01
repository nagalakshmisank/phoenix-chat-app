import Config

config :phoenix, :json_library, Jason

config :mime, :types, %{
  "application/activity+json" => ["activity+json"]
}

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Database (Oban job queue only)
config :przma, PRZMA.Repo,
  database: "przma",
  username: "postgres",
  password: "1245",
  hostname: "localhost",
  pool_size: 10

# Oban job queue
config :przma, Oban,
  engine: Oban.Engines.Basic,
  queues: [default: 10, priority: 5],
  repo: PRZMA.Repo

# S3 / Object store configuration
config :ex_aws,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID", "minioadmin"),
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY", "minioadmin"),
  region: System.get_env("AWS_REGION", "in-maa-1")

# Base URL for generating blob URLs in activity raw_json
config :przma, :base_url, System.get_env("PRZMA_BASE_URL", "http://172.235.18.126:4201")

# Development overrides
if Mix.env() == :dev do
  config :logger, level: :debug
end

# Production overrides
if Mix.env() == :prod do
  config :logger, level: :info
end
