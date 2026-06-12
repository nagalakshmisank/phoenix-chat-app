import Config

# Runtime configuration — loaded at startup, not compile-time

database_url =
  System.get_env("DATABASE_URL") ||
    "ecto://postgres:postgres@localhost/przma"

config :przma, PRZMA.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: String.to_existing_atom(System.get_env("DATABASE_SSL") || "false")

# S3 endpoint (MinIO, AWS, or Linode Object Storage)
s3_endpoint = System.get_env("S3_ENDPOINT", "https://in-maa-1.linodeobjects.com")
s3_bucket = System.get_env("S3_BUCKET", "przma-vaults")
s3_region =
  System.get_env("S3_REGION") ||
    System.get_env("AWS_DEFAULT_REGION") ||
    System.get_env("AWS_REGION") ||
    "in-maa-1"

config :przma, :s3_bucket, s3_bucket

# pzdb NIF base_path. When this is an s3:// URI, LanceDB writes straight to the
# object store. The NIF (object_store) reads endpoint/region/credentials from
# AWS_ENDPOINT / AWS_DEFAULT_REGION / AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# in the OS environment — make sure those are exported before `mix phx.server`.
#
# For development: defaults to local temp directory (set VAULT_BASE_PATH for S3)
vault_base_path =
  System.get_env("VAULT_BASE_PATH") ||
    (if config_env() == :prod do
       "s3://#{s3_bucket}/lancedb"
     else
       Path.join([System.tmp_dir!(), "przma_vaults"])
     end)

config :przma, :vault_base_path, vault_base_path

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
    region: s3_region
end
