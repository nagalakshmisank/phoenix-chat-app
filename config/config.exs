import Config

config :pzdb, :vault,
  base_path: System.get_env("PRZMA_LOCAL_PATH", "/tmp/przma_vaults")
