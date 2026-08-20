import Config

# Loaded automatically by Mix at boot (dev, test, and releases) — this
# is where the real Tier-1 S3/Keycloak env vars from your deployment
# get read. Safe defaults let `mix phx.server` boot without every var
# set, but a real write will fail without real AWS_* credentials.

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :przma, PRZMAWeb.Endpoint, secret_key_base: secret_key_base
end

config :przma, :keycloak,
  url: System.get_env("KEYCLOAK_URL", "http://172.235.18.126:8180"),
  realm: System.get_env("KEYCLOAK_REALM", "przma")

config :przma, :vault,
  base_path: System.get_env("VAULT_BASE_PATH", "s3://perkeep"),
  cas_backend: System.get_env("CAS_BACKEND", "s3"),
  s3_bucket: System.get_env("S3_BUCKET", "perkeep"),
  s3_endpoint: System.get_env("AWS_ENDPOINT", "https://in-maa-1.linodeobjects.com"),
  s3_region: System.get_env("S3_REGION", "in-maa-1"),
  s3_access_key: System.get_env("AWS_ACCESS_KEY_ID"),
  s3_secret_key: System.get_env("AWS_SECRET_ACCESS_KEY")

# Read directly by PRZMA.PzDb.global_base/0 (lib/przma/pzdb/pzdb.ex) —
# this is the REAL production config key, different from the :vault
# block above (which was this project's own earlier convention before
# the real pzdb.ex/nif.ex were found). Both are set from the same env
# var so nothing breaks; PzDb only reads this one.
config :przma, :vault_base_path, System.get_env("VAULT_BASE_PATH", "s3://perkeep")
