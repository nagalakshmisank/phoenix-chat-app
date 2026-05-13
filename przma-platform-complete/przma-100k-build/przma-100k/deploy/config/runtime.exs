# deploy/config/runtime.exs
#
# Runtime configuration — reads from environment variables.
# This config is evaluated at application startup (not compile time).
# Works for all four deployment modes: cloud_saas, byos, local, own_domain.

import Config

# ── Deployment mode detection ─────────────────────────────────────────────────
mode = case System.get_env("PRZMA_MODE", "own_domain") do
  "cloud_saas"  -> :cloud_saas
  "byos"        -> :byos
  "local"       -> :local
  _             -> :own_domain
end

config :przma, :deployment_mode, mode

# ── Instance configuration ────────────────────────────────────────────────────
instance_url = System.get_env("PRZMA_INSTANCE_URL") ||
  raise "PRZMA_INSTANCE_URL environment variable is required"

instance_uri = URI.parse(instance_url)

config :przma, :instance, [
  url:  instance_url,
  host: instance_uri.host,
]

# ── Vault storage ─────────────────────────────────────────────────────────────
base_path = System.get_env("PRZMA_LOCAL_PATH", "/data/vaults")

config :przma, :vault, [
  base_path: base_path,
  s3_endpoint:   System.get_env("PRZMA_S3_ENDPOINT"),
  s3_bucket:     System.get_env("PRZMA_S3_BUCKET",  "przma-vaults"),
  s3_region:     System.get_env("PRZMA_S3_REGION",  "us-east-1"),
  s3_access_key: System.get_env("PRZMA_S3_ACCESS_KEY"),
  s3_secret:     System.get_env("PRZMA_S3_SECRET"),
]

# ── Encryption ────────────────────────────────────────────────────────────────
config :przma, :encryption, [
  enabled:    true,
  key_source: if(mode in [:local, :own_domain], do: :file, else: :env),
]

# ── Phoenix Endpoint ──────────────────────────────────────────────────────────
secret_key_base = System.get_env("SECRET_KEY_BASE") ||
  raise "SECRET_KEY_BASE environment variable is required"

config :przma, PRZMAWeb.Endpoint,
  secret_key_base: secret_key_base,
  url: [
    host:   instance_uri.host,
    scheme: instance_uri.scheme || "https",
    port:   instance_uri.port   || 443,
  ],
  http: [port: String.to_integer(System.get_env("PORT", "4000"))],
  server: true

# ── Database (Oban job queue) ─────────────────────────────────────────────────
database_url = System.get_env("DATABASE_URL") ||
  "postgresql://przma:insecure@localhost/przma"

config :przma, PRZMA.Repo,
  url:      database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

# ── Oban (job queue backend) ──────────────────────────────────────────────────
oban_config = case mode do
  m when m in [:local, :own_domain] ->
    # SQLite for local/own_domain — no PostgreSQL required
    sqlite_path = Path.join(base_path, "jobs/oban.db")
    File.mkdir_p!(Path.dirname(sqlite_path))
    [
      repo:   PRZMA.SQLiteRepo,
      engine: Oban.Engines.Basic,
      queues: [default: 10, reminders: 5, circle_sync: 3, federation: 5, intelligence: 3, maintenance: 2],
    ]
  _ ->
    # PostgreSQL for cloud_saas/byos
    [
      repo:   PRZMA.Repo,
      queues: [default: 10, reminders: 5, circle_sync: 3, federation: 5, intelligence: 3, maintenance: 2],
      plugins: [Oban.Plugins.Pruner, Oban.Plugins.Lifeline],
    ]
end

config :przma, Oban, oban_config

# ── Erlang cluster (libcluster for multi-node) ────────────────────────────────
cluster_strategy = case System.get_env("PRZMA_CLUSTER_STRATEGY", "gossip") do
  "dns"    -> Cluster.Strategy.DNSPoll
  "gossip" -> Cluster.Strategy.Gossip
  _        -> Cluster.Strategy.Gossip
end

config :libcluster,
  topologies: [
    przma: [
      strategy: cluster_strategy,
      config: [
        # Gossip (default, works on any private network)
        port:            45892,
        if_addr:         System.get_env("PRZMA_PRIVATE_IP", "0.0.0.0"),
        multicast_addr:  "230.1.1.251",
        broadcast_only:  true,
        # DNS poll (for Kubernetes or known hostnames)
        query:           System.get_env("PRZMA_CLUSTER_DNS", "przma-nodes.internal"),
        node_basename:   "przma",
        polling_interval: 5_000,
      ],
    ],
  ]

# ── Email (optional) ──────────────────────────────────────────────────────────
if smtp_host = System.get_env("SMTP_HOST") do
  config :przma, PRZMA.Mailer,
    adapter:  Swoosh.Adapters.SMTP,
    relay:    smtp_host,
    port:     String.to_integer(System.get_env("SMTP_PORT", "587")),
    username: System.get_env("SMTP_USER"),
    password: System.get_env("SMTP_PASS"),
    tls:      :always,
    from:     System.get_env("SMTP_FROM", "noreply@#{instance_uri.host}")
else
  # Use local (logs emails to console — good for development)
  config :przma, PRZMA.Mailer, adapter: Swoosh.Adapters.Local
end

# ── ActivityPub ───────────────────────────────────────────────────────────────
config :przma, :activitypub, [
  enabled:      System.get_env("PRZMA_AP_ENABLED", "true") == "true",
  instance_url: instance_url,
]

# ── Telemetry / Observability ─────────────────────────────────────────────────
# Configure your metrics backend here.
# For Prometheus: plug in PromEx or Telemetry.Metrics
# For Grafana Cloud: use the OTEL exporter
#
# Defaults to no-op (telemetry events are still emitted internally).
config :przma, :telemetry, [
  enabled: System.get_env("PRZMA_TELEMETRY_ENABLED", "true") == "true",
  # otel_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"),
]
