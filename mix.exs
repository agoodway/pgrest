defmodule PgRest.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agoodway/pgrest"

  def project do
    [
      app: :pgrest,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      description: description(),
      package: package(),
      name: "PgRest",
      source_url: @source_url,
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix, :ex_unit], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  def cli do
    [preferred_envs: [quality: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      test: ["ecto.create --quiet -r PgRest.Integration.Repo", "test"],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "sobelow --config",
        "ex_dna",
        "doctor",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.20"},
      {:telemetry, "~> 1.4"},
      {:ecto, "~> 3.14"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},

      # Dev/Test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.19", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},

      # Integration test deps
      {:supabase_potion, "~> 1.0", only: :test},
      {:supabase_postgrest, "~> 1.3", only: :test},
      {:bandit, "~> 1.14", only: :test}
    ]
  end

  defp description do
    "A PostgREST and Supabase-compatible REST API powered by Elixir and Ecto."
  end

  defp package do
    [
      maintainers: ["Chase Pursley"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
