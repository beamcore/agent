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
      releases: [
        agent: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Beamcore.Agent, []}
    ]
  end

  defp deps do
    [
      {:openai_ex, "~> 0.9.21"},
      {:number, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
