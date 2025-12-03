defmodule Chat.MixProject do
  use Mix.Project

  def project do
    [
      app: :chat,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {Chat.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Phoenix Framework
      {:phoenix, "~> 1.7.10"},
      {:phoenix_ecto, "~> 4.4"},
      {:phoenix_live_dashboard, "~> 0.8.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},

      # Database
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},

      # JSON
      {:jason, "~> 1.4"},

      # Authentication
      {:joken, "~> 2.6"},
      {:bcrypt_elixir, "~> 3.0"},

      # Rate Limiting
      {:hammer, "~> 6.1"},

      # Push Notifications
      {:pigeon, "~> 2.0"},

      # Broadway for async processing
      {:broadway, "~> 1.0"},
      {:gen_stage, "~> 1.2"},

      # HTTP Client
      {:finch, "~> 0.16"},

      # Presence
      {:phoenix_pubsub, "~> 2.1"},

      # Observability
      {:prom_ex, "~> 1.9"},

      # Production
      {:plug_cowboy, "~> 2.5"},
      {:dns_cluster, "~> 0.1.1"},

      # Development & Test
      {:phoenix_live_reload, "~> 1.4", only: :dev},
      {:swoosh, "~> 1.14", only: [:dev, :test]},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2.0", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind default", "esbuild default"],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
    ]
  end

  defp releases do
    [
      chat: [
        include_executables_for: [:unix],
        applications: [runtime_tools: :permanent],
        steps: [:assemble, :tar],
        cookie: "${RELEASE_COOKIE}"
      ]
    ]
  end
end
