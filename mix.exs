defmodule Beamcore.Agent.MixProject do
  use Mix.Project

  @version "1.0.0"

  def project do
    [
      app: :beamcore,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A general-purpose CLI coding agent",
      license: "MIT",
      links: %{"GitHub" => "https://github.com/beamcore/agent"},

      # For advanced users (release)
      releases: [
        beamcore: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent, beamcore: :permanent],
          config_providers: [Mix.Release.Config.Env],
          steps: [:assemble],
          executables: [
            beamcore: [
              main_module: Beamcore.Agent
            ]
          ]
        ]
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md", "CONTRIBUTING.md", "LICENSE"],
        source_ref: "v" <> @version,
        source_url: "https://github.com/beamcore/agent"
      ],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/beamcore/agent"},
        files: ["lib", "mix.exs", "README.md", "LICENSE"],
        maintainers: ["Beamcore Team"],
        hexpm: [
          repo: "hexpm",
          username: "beamcore"
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl],
      mod: {Beamcore.Agent, []}
    ]
  end

  defp deps do
    [
      {:html2markdown, "~> 0.3.1"},
      {:openai_ex, "~> 0.9.21"},
      {:number, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.6"},
      {:ex_ratatui, "~> 0.11.0"},
      {:rustler, "~> 0.36", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
