defmodule Beamcore.Agent.Tools.Rust do
  @moduledoc "Allowlisted Rust/Cargo workflow tool."

  alias Beamcore.Agent.Tools.CommandRunner

  @allowed_commands ~w(test check fmt clippy build)
  @description "Run allowlisted Cargo commands: test, check, fmt, clippy, and build."

  def name, do: "rust"

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
      CommandRunner.run(name(), command, "cargo", command_args(command) ++ extra(params),
        workdir: Map.get(params, "workdir", ".")
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp command_args("test"), do: ["test"]
  defp command_args("check"), do: ["check"]
  defp command_args("fmt"), do: ["fmt", "--check"]
  defp command_args("clippy"), do: ["clippy", "--", "-D", "warnings"]
  defp command_args("build"), do: ["build"]
  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))
end
