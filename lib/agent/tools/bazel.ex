defmodule Beamcore.Agent.Tools.Bazel do
  @moduledoc "Allowlisted Bazel workflow tool."

  alias Beamcore.Agent.Tools.CommandRunner

  @allowed_commands ~w(test build query)
  @description "Run allowlisted Bazel commands: test, build, and query. Run is not exposed."

  def name, do: "bazel"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", enum: @allowed_commands},
            target: %{type: "string", description: "Bazel target or query expression"},
            args: %{type: "string"},
            workdir: %{type: "string"}
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(params) do
    command = Map.fetch!(params, "command")

    if command in @allowed_commands do
      target = Map.get(params, "target", "//...")

      CommandRunner.run(name(), command, "bazel", [command, target] ++ extra(params),
        workdir: Map.get(params, "workdir", ".")
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))
end
