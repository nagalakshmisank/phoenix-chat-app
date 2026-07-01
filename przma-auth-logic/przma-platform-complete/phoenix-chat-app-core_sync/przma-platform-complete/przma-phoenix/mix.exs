defmodule PRZMA.MixProject do
  use Mix.Project

  def project do
    [
      app: :przma,
      version: "0.1.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PRZMA.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix & web
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:plug_cowboy, "~> 2.6"},

      # OpenAPI / Swagger 
      {:open_api_spex, "~> 3.18"},

      # Rust NIF bridge (pzdb → LanceDB → S3)
      {:rustler, "~> 0.36.0"},

      # JSON
      {:jason, "~> 1.4"},

      # Internationalization
      {:gettext, "~> 0.24"},

      # Database & Ecto (for Oban job queue)
      {:ecto_sql, "~> 3.10"},
      {:postgrex, "~> 0.17"},

      # Object storage (S3)
      {:ex_aws, "~> 2.5"},
      {:ex_aws_s3, "~> 2.5"},
      # ExAws needs an HTTP client (hackney) and an XML parser (sweet_xml)
      # for S3 request signing/response parsing.
      {:hackney, "~> 1.20"},
      {:sweet_xml, "~> 0.7"},

      # Job queue
      {:oban, "~> 2.14"},

      # Time
      {:timex, "~> 3.7"},

      # Logging
      {:logger_json, "~> 5.1"},

      # Auth 
      {:pbkdf2_elixir, "~> 2.0"},

      # Dev & test
      {:ex_doc, "~> 0.30", only: :dev},
      {:mix_test_watch, "~> 1.1", only: :dev},
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
    ]
  end
end

