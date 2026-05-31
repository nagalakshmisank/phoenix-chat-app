defmodule PzDb.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [PRZMA.PzDb.Supervisor]
    Supervisor.start_link(children, strategy: :one_for_one, name: PzDb.Supervisor)
  end
end
