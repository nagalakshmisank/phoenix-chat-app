defmodule PRZMA.PromEx do
  use PromEx, otp_app: :przma

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: PRZMAWeb.Router, endpoint: PRZMAWeb.Endpoint}
      # Repo/Oban are commented out in application.ex right now, so these two
      # stay commented until PRZMA.Repo is actually started as a child:
      # Plugins.Ecto,
      # Plugins.Oban
    ]
  end

  @impl true
  def dashboard_assigns do
    [datasource_id: "Prometheus", default_selected_interval: "30s"]
  end

  @impl true
  def dashboards do
    [
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"}
    ]
  end
end