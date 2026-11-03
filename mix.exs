defmodule Contentoid.MixProject do
  use Mix.Project

  def project do
    [
      app: :contentoid,
      version: "0.0.1",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:iconex],
      # File references without line numbers, so `gettext.extract --check-up-to-date` (precommit)
      # fails on changed msgids only, not on code that moved.
      gettext: [write_reference_line_numbers: false],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Contentoid.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    # quokka:sort
    [
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:crontab, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:ecto_sql, "~> 3.13"},
      {:gettext, "~> 1.0"},
      {:iconex, "~> 0.1.0"},
      {:jason, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:localize, "~> 1.6"},
      {:localize_web, "~> 1.0"},
      {:oban, "~> 2.24"},
      {:phoenix, "~> 1.8.16"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:postgrex, ">= 0.0.0"},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false},
      {:req, "~> 0.7.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:tz, "~> 0.28.4"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "localize.download_locales", "ecto.setup", "cmd --cd assets bun install", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.build": ["compile", "cmd --cd assets env NODE_PATH=../deps:../_build/#{Mix.env()} bun run build.ts"],
      "assets.deploy": [
        "compile",
        "cmd --cd assets env NODE_PATH=../deps:../_build/#{Mix.env()} bun run build.ts deploy",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        # In a build directory of its own: the extractor force-recompiles the app after protocols are
        # consolidated, which leaves the build it runs in warning on the next compile.
        "cmd env MIX_ENV=test MIX_BUILD_PATH=_build/gettext mix gettext.extract --check-up-to-date",
        "cmd mise exec oxlint -- oxlint --deny-warnings assets/js _build/test/phoenix-colocated/contentoid",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
