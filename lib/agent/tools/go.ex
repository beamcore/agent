defmodule Beamcore.Agent.Tools.Go do
  @moduledoc "Allowlisted Go workflow tool."

  alias Beamcore.Agent.Tools.CommandRunner

  @allowed_commands ~w(test fmt vet build mod-tidy)
  @description "Run allowlisted Go commands: test, fmt, vet, build, and mod-tidy."

  def name, do: "go"

  def spec do
    tool_spec(name(), @description, @allowed_commands)
  end

  def execute(params), do: run(params, &command_argv/2)

  defp command_argv("test", params), do: {"go", ["test", "./..."] ++ extra(params)}
  defp command_argv("fmt", params), do: {"go", ["fmt", "./..."] ++ extra(params)}
  defp command_argv("vet", params), do: {"go", ["vet", "./..."] ++ extra(params)}
  defp command_argv("build", params), do: {"go", ["build", "./..."] ++ extra(params)}
  defp command_argv("mod-tidy", params), do: {"go", ["mod", "tidy"] ++ extra(params)}

  defp run(params, mapper) do
    command = Map.fetch!(params, "command")

    if command in @allowed_commands do
      {executable, args} = mapper.(command, params)

      CommandRunner.run(name(), command, executable, args,
        workdir: Map.get(params, "workdir", ".")
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))

  defp tool_spec(name, description, commands) do
    %{
      type: "function",
      function: %{
        name: name,
        description: description,
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", enum: commands},
            args: %{type: "string"},
            workdir: %{type: "string"}
          },
          required: ["command"]
        }
      }
    }
  end
end
