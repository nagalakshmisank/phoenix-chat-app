defmodule ChatApi.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ets.new(:chat_messages, [:named_table, :public, :ordered_set])
    :ets.new(:chat_rooms,    [:named_table, :public, :set])

    children = [
      ChatApiWeb.Endpoint,
      {Phoenix.PubSub, name: ChatApi.PubSub},
      ChatApiWeb.Presence
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ChatApi.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChatApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
