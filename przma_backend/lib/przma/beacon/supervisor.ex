defmodule Przma.Beacon.Supervisor do
  @moduledoc """
  Starts everything Beacon needs, as ONE isolated branch of the app:

      Przma.Beacon.Repo                  -> becam_cms connection pool
      Przma.Beacon.UserActivityCollector -> batches activity into becam_cms
      Beacon (site :przma)               -> Beacon CMS runtime
      PRZMAWeb.Beacon.AdminEndpoint      -> /admin on port 4300

  Isolation from the platform (profile, files, registration, API):

    * application.ex starts this supervisor with `restart: :temporary`, so
      even if Beacon keeps crashing, only this branch stops — the API's
      endpoint, CouchDB, S3 and CAS processes are never restarted by it.
    * BEACON_ENABLED is not "true"  ->  this supervisor starts nothing.
  """
  use Supervisor
  require Logger

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Child spec used in application.ex: never restarted by the main supervisor."
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor, restart: :temporary}
  end

  @impl true
  def init(_opts) do
    children =
      if Przma.Beacon.enabled?() do
        Logger.info("[beacon] enabled — admin on port #{admin_port()}")

        [
          Przma.Beacon.Repo,
          Przma.Beacon.UserActivityCollector,
          {Beacon, sites: [Application.fetch_env!(:beacon, :przma)]},
          PRZMAWeb.Beacon.AdminEndpoint
        ]
      else
        Logger.info("[beacon] disabled (export BEACON_ENABLED=true to turn it on)")
        []
      end

    # Up to 5 restarts per minute inside Beacon; beyond that only Beacon stops.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

  defp admin_port do
    get_in(Application.get_env(:przma, PRZMAWeb.Beacon.AdminEndpoint, []), [:http, :port])
  end
end
