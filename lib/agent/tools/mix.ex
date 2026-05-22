defmodule Beamcore.Agent.Tools.Mix do
  @moduledoc """
  Safe, scoped wrapper for mix commands.
  """

  @allowed_commands ~w(test compile format deps.get dialyzer hex.info)

  @description """
  Run safe, scoped Elixir mix commands such as test, compile, format, dialyzer, and deps.get.
  Automatically manages the MIX_ENV and truncates extremely long command outputs.
  An essential tool for Elixir compilation, testing, and dependency resolution.
  """

  def name, do: "mix"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            command: %{type: "string", description: "The mix subcommand to run (e.g. 'test')"},
            args: %{
              type: "string",
              description: "Additional arguments as a single string",
              default: ""
            }
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(params) do
    command = Map.fetch!(params, "command")

    if command in @allowed_commands do
      extra = String.split(Map.get(params, "args", ""), " ", trim: true)
      env = [{"MIX_ENV", mix_env(command)}]

      case System.cmd("mix", [command | extra], stderr_to_stdout: true, env: env) do
        {output, 0} -> truncate(output)
        {output, _} -> "mix #{command} failed:\n#{truncate(output)}"
      end
    else
      "Disallowed command '#{command}'. Allowed: #{Enum.join(@allowed_commands, ", ")}"
    end
  end

  defp mix_env("test"), do: "test"
  defp mix_env(_), do: "dev"

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
