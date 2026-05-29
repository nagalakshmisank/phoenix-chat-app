defmodule PzDb.MixProject do
  use Mix.Project

  def project do
    [
      app:             :pzdb,
      version:         "0.1.0",
      elixir:          "~> 1.15",
      start_permanent: false,
      deps:            deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {PzDb.Application, []}
    ]
  end

  defp deps do
    [
      {:jason,     "~> 1.4"},
      {:telemetry, "~> 1.2"},
    ]
  end
end
