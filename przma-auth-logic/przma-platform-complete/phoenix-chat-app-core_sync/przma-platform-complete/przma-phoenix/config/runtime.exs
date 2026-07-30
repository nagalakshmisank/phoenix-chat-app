import Config

# Runtime configuration — loaded at startup, not compile-time

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://postgres:postgres@localhost/przma"

config :przma, PRZMA.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: String.to_existing_atom(System.get_env("DATABASE_SSL") || "false")

# S3 endpoint (MinIO, AWS, or Linode Object Storage).
# Accept both PRZMA-style (S3_*) and AWS/Linode-style (ENDPOINT/BUCKET/
# AWS_DEFAULT_REGION) env var names so the same deploy env works for both the
# Elixir ExAws client and the Rust object_store NIF.
s3_endpoint =
  System.get_env("S3_ENDPOINT") ||
    System.get_env("AWS_ENDPOINT") ||
    System.get_env("ENDPOINT") ||
    "http://localhost:9000"

s3_bucket =
  System.get_env("S3_BUCKET") ||
    System.get_env("BUCKET") ||
    "perkeep"

s3_region =
  System.get_env("S3_REGION") ||
    System.get_env("AWS_DEFAULT_REGION") ||
    System.get_env("AWS_REGION") ||
    "us-east-1"

config :przma, :s3_bucket, s3_bucket

# CAS blob storage backend: "s3" or "local".
# Defaults to s3 in prod, local in dev — override with CAS_BACKEND.
cas_backend =
  System.get_env("CAS_BACKEND") ||
    if(config_env() == :prod, do: "s3", else: "local")

config :przma, :cas_backend, cas_backend

# pzdb NIF base_path. When this is an s3:// URI, LanceDB writes straight to the
# object store. The NIF (object_store) reads endpoint/region/credentials from
# AWS_ENDPOINT / AWS_DEFAULT_REGION / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# in the OS environment — make sure those are exported before `mix phx.server`.
#
# For development: defaults to local temp directory (set VAULT_BASE_PATH for S3)
vault_base_path =
  (System.get_env("VAULT_BASE_PATH") ||
     (if config_env() == :prod do
        # DID sits at the bucket root so Lance tables live alongside CAS blobs:
        #   s3://{bucket}/{did}/files/{space}/files.lance
        #   s3://{bucket}/{did}/cas/{shard}/{hash}
        "s3://#{s3_bucket}"
      else
        Path.join([System.tmp_dir!(), "przma_vaults"])
      end))
  |> String.trim_trailing("/")
  # Defensive: the DID must sit at the bucket root, never under a "lancedb/"
  # folder. Strip a stray trailing "/lancedb" left over from older configs.
  |> String.replace_suffix("/lancedb", "")

config :przma, :vault_base_path, vault_base_path

# Normalize the OS environment so the Rust object_store NIF (which reads AWS_*
# straight from the OS env, not from app config) sees the same endpoint and
# region as the Elixir ExAws client — regardless of which name was exported.
# Runs at boot, before the NIF performs any S3 operation.
if endpoint = System.get_env("AWS_ENDPOINT") || System.get_env("ENDPOINT") || System.get_env("S3_ENDPOINT") do
  System.put_env("AWS_ENDPOINT", endpoint)
end

System.put_env("AWS_DEFAULT_REGION", s3_region)

config :ex_aws,
  access_key_id: System.get_env("AWS_ACCESS_KEY_ID") || "minioadmin",
  secret_access_key: System.get_env("AWS_SECRET_ACCESS_KEY") || "minioadmin",
  region: s3_region

if config_env() != :test do
  # Parse the endpoint URI so scheme/host/port are correct for any provider
  uri = URI.parse(s3_endpoint)

  config :ex_aws, :s3,
    scheme: "#{uri.scheme}://",
    host: uri.host,
    port: uri.port || (if uri.scheme == "https", do: 443, else: 80),
    region: s3_region,
    bucket: s3_bucket,
    virtual_host: false

   
end

#port = String.to_integer(System.get_env("PORT") || "4000")
#config :przma, PRZMAWeb.Endpoint,
 # http: [ip: {0, 0, 0, 0}, port: port],
  #secret_key_base: System.get_env("SECRET_KEY_BASE")

socket_port = String.to_integer(System.get_env("SOCKET_PORT") || "4001")

config :przma, PRZMAWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: socket_port],
  secret_key_base:
    System.get_env("SECRET_KEY_BASE") ||
      "przma_dev_insecure_secret_key_base_change_me_before_prod_0000000000",
  live_view: [signing_salt: "przma_console_signing_salt_change_me"],   
  pubsub_server: PRZMA.PubSub,
  server: true
