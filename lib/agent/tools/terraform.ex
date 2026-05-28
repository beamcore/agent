defmodule Beamcore.Agent.Tools.Terraform do
  @moduledoc "Allowlisted Terraform workflow tool."

  alias Beamcore.Agent.Tools.CommandRunner

  @allowed_commands ~w(fmt validate plan)
  @description "Run allowlisted Terraform commands: fmt, validate, and plan. Apply/destroy are not exposed."

  def name, do: "terraform"

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
      CommandRunner.run(name(), command, "terraform", command_args(command) ++ extra(params),
        workdir: Map.get(params, "workdir", ".")
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp command_args("fmt"), do: ["fmt", "-check"]
  defp command_args("validate"), do: ["validate"]
  defp command_args("plan"), do: ["plan", "-input=false"]
  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))
end
