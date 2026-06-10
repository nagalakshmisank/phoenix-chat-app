defmodule PRZMA.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # File sync endpoints don't need database — skip Repo and Oban
      # PRZMA.Repo,
      # {Oban, Application.fetch_env!(:przma, Oban)},

      # Phoenix HTTP server
      {Plug.Cowboy, scheme: :http, plug: PRZMAWeb.Router, options: [port: 4000]},
    ]

    opts = [strategy: :one_for_one, name: PRZMA.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
