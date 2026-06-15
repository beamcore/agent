defmodule Beamcore.Agent.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent,
      version: "0.1.0",
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A general-purpose CLI coding agent",
      license: "MIT",
      links: %{"GitHub" => "https://github.com/beamcore/agent"},

      # For advanced users (release)
      releases: [
        agent: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent, agent: :permanent],
          config_providers: [Mix.Release.Config.Env],
          steps: [:assemble],
          executables: [
            agent: [
              main_module: Beamcore.Agent
            ]
          ]
        ]
      ],
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/beamcore/agent"},
        files: ["lib", "src", "mix.exs", "README.md", "LICENSE"],
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
      {:openai_ex, "~> 0.9.21"},
      {:number, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:ex_ratatui, "~> 0.10.0"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end
end
