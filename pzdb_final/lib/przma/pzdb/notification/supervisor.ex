# lib/przma/pzdb/notification/supervisor.ex
#
# Supervisor for the notification subsystem.
# Add PRZMA.PzDb.Notification.Supervisor to your application's supervision tree,
# OR add it as a child of PRZMA.PzDb.Supervisor.
#
# Supervises:
#   - StorageHealth — periodic local storage health check (GenServer)
#
# Add more workers here as the system grows (e.g. a delivery retry worker,
# a scheduled-message dispatcher, a push notification bridge).

defmodule PRZMA.PzDb.Notification.Supervisor do
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      PRZMA.PzDb.Notification.StorageHealth,
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

defmodule PRZMA.PzDb.Notification.StorageHealth do
  @moduledoc """
  Periodically checks local storage accessibility and emits telemetry.
  Fires :local_storage_health_check every 60 seconds.
  """
  use GenServer
  require Logger

  alias PRZMA.PzDb.Notification.Storage

  @check_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{healthy: nil, last_check: nil, failures: 0}}
  end

  @impl true
  def handle_info(:check, state) do
    now    = DateTime.utc_now()
    result = Storage.health_check()

    new_state =
      case result do
        :ok ->
          if state.healthy == false do
            Logger.info("Local storage recovered")
          end
          :telemetry.execute([:przma, :local_storage, :health], %{healthy: 1}, %{})
          %{state | healthy: true, last_check: now, failures: 0}

        {:error, reason} ->
          Logger.warning("Local storage health check failed",
            reason: reason, consecutive_failures: state.failures + 1)
          :telemetry.execute([:przma, :local_storage, :health], %{healthy: 0}, %{reason: reason})
          %{state | healthy: false, last_check: now, failures: state.failures + 1}
      end

    schedule_check()
    {:noreply, new_state}
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state, state}

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end
end
