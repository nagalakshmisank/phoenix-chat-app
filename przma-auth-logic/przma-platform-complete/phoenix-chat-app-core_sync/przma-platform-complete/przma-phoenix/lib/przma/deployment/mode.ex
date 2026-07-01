# lib/przma/deployment/mode.ex
#
# Deployment mode detection, configuration, and runtime management.
# Determines whether PRZMA is running as Cloud SaaS, BYOS, Local, or Own Domain.
# Exposes the active mode to all calendar and storage subsystems.

defmodule PRZMA.Deployment.Mode do
  use GenServer
  require Logger

  @modes ~w(cloud_saas byos local own_domain)

  # ── PUBLIC API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the current deployment mode atom"
  def current, do: GenServer.call(__MODULE__, :mode)

  @doc "Get full deployment configuration map"
  def config, do: GenServer.call(__MODULE__, :config)

  @doc "Check if running in a local (non-cloud) mode"
  def local?,      do: current() in [:local, :own_domain]
  def cloud?,      do: current() in [:cloud_saas, :byos]
  def byos?,       do: current() == :byos
  def own_domain?, do: current() == :own_domain

  @doc "Get the vault base path for the current mode"
  def vault_base_path, do: GenServer.call(__MODULE__, :vault_base_path)

  @doc "Get S3 credentials for BYOS mode (nil if not BYOS)"
  def s3_credentials(did), do: GenServer.call(__MODULE__, {:s3_creds, did})

  # ── GENSERVER ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    config = detect_configuration()
    Logger.info("PRZMA deployment mode detected",
      mode: config.mode, is_local: config.is_local)
    {:ok, config}
  end

  @impl true
  def handle_call(:mode,            _from, state), do: {:reply, state.mode,           state}
  def handle_call(:config,          _from, state), do: {:reply, state,                state}
  def handle_call(:vault_base_path, _from, state), do: {:reply, state.vault_base_path, state}

  def handle_call({:s3_creds, did}, _from, state) do
    creds = case state.mode do
      :byos -> Map.get(state.byos_credentials, did)
      _     -> nil
    end
    {:reply, creds, state}
  end

  # ── MODE DETECTION ────────────────────────────────────────────────────────

  defp detect_configuration do
    mode = detect_mode()
    %{
      mode:            mode,
      is_local:        mode in [:local, :own_domain],
      is_cloud:        mode in [:cloud_saas, :byos],
      vault_base_path: vault_base_path_for(mode),
      instance_url:    instance_url(),
      encryption:      encryption_config(),
      byos_credentials: %{},
      license:         License.load(),
    }
  end

  defp detect_mode do
    cond do
      System.get_env("PRZMA_MODE") == "byos"       -> :byos
      System.get_env("PRZMA_MODE") == "own_domain"  -> :own_domain
      System.get_env("PRZMA_LOCAL_PATH") != nil      -> :local
      Application.get_env(:przma, :deployment_mode) -> Application.get_env(:przma, :deployment_mode)
      true                                           -> :cloud_saas
    end
  end

  defp vault_base_path_for(mode) do
    case mode do
      :local      -> System.get_env("PRZMA_LOCAL_PATH", "/var/przma/vaults")
      :own_domain -> System.get_env("PRZMA_LOCAL_PATH", "/var/przma/vaults")
      :byos       -> Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")
      :cloud_saas -> Application.get_env(:przma, [:vault, :base_path], "/var/przma/vaults")
    end
  end

  defp instance_url do
    System.get_env("PRZMA_INSTANCE_URL") ||
    Application.get_env(:przma, [:instance, :url], "https://przma.ai")
  end

  defp encryption_config do
    %{
      enabled:    Application.get_env(:przma, [:encryption, :enabled], true),
      key_source: Application.get_env(:przma, [:encryption, :key_source], :env),
    }
  end
end
