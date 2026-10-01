defmodule Przma.MixProject do
  use Mix.Project

  def project do
    [
      app: :przma,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Przma.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      # JWT/JWKS verification for the KeycloakAuth plug
      {:jose, "~> 1.11"},
      # Real LanceDB NIF, found in the mentor's other repo
      # (phoenix-chat-app-circle) and confirmed as genuine (not a
      # stub) — see native/przma_pzdb_nif/src/lib.rs and
      # lib/przma/pzdb/{nif,pzdb}.ex. NOT verified compiling by me —
      # this sandbox's Rust toolchain is too old (apt-only, 1.75.0;
      # a transitive dep needs edition2024). Build it with your real
      # toolchain (per the crate's own Cargo.toml notes: lancedb 0.9 +
      # arrow 52.2.0, or fall back to lancedb 0.10 + arrow 53 if you
      # hit the lance recursion-overflow error).
      {:rustler, "~> 0.36"},
      # Swagger UI — same version and wiring pattern as your real,
      # already-working project (lib/przma_web/api_spec.ex ports that
      # project's PRZMAWeb.ApiSpec, scoped to this project's 4 real
      # endpoints). Ships its own SwaggerUI assets — no CDN dependency,
      # unlike the version this replaces.
      {:open_api_spex, "~> 3.18"},
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      # override: true — Beacon 0.5.1 pins ex_aws/ex_aws_s3 to ~> 2.4.0 (for its
      # media-library S3 multipart copy, which we don't use). We keep 2.5+.
      {:ex_aws, "~> 2.5", override: true},
      {:ex_aws_s3, "~> 2.5", override: true},
      {:sweet_xml, "~> 0.7"},
      {:hackney, "~> 1.20"},
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.0.0"},

      # ── Beacon CMS admin dashboard (lib/przma/beacon, lib/przma_web/beacon) ──
      # Only RUNS when BEACON_ENABLED=true; see lib/przma/beacon/supervisor.ex.
      {:beacon, "~> 0.5.1"},
      {:beacon_live_admin, "~> 0.4.3"},
      {:phoenix_live_view, "~> 1.0.0"},
      {:phoenix_html, "~> 4.1"},
      # Pins that keep Elixir 1.16 working (newer versions need Elixir 1.17):
      {:image, "~> 0.63.0"},
      {:live_svelte, "~> 0.16.0"},
      # Markdown engine version Beacon 0.5.1 was released against
      {:mdex, "~> 0.5.0"},

      {:cowlib, "~> 2.13.0", override: true},
      # Pinned below 2.2 — ranch 2.2+ calls :proc_lib.set_label/1,
      # which only exists on OTP 27+. This container runs OTP 26
      # (erts-14.2.5.12), so anything >= 2.2 crashes
      # PRZMAWeb.Endpoint on boot with an UndefinedFunctionError.
      {:ranch, "~> 2.1.0", override: true}
    ]
  end
end
