defmodule Beamcore.Agent.Tools.Node do
  @moduledoc """
  Allowlisted Node.js/npm/npx workflow tool.
  """

  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @allowed_commands ~w(test lint build format install npx-playwright-test npx-playwright-show-report)
  @description """
  Run allowlisted Node.js workflow commands. Arbitrary npx packages are not supported.
  """

  def name, do: "node"

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
            args: %{type: "string", description: "Extra argv appended to the allowlisted command"},
            workdir: %{type: "string", description: "Workspace-relative workdir"}
          },
          required: ["command"]
        }
      }
    }
  end

  def execute(params) do
    command = Map.fetch!(params, "command")

    if command in @allowed_commands do
      {executable, args} = command_argv(command, params)

      CommandRunner.run(name(), command, executable, args,
        workdir: Map.get(params, "workdir", "."),
        classification: classification(command)
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp command_argv("test", params), do: {"npm", ["test"] ++ extra(params)}
  defp command_argv("lint", params), do: {"npm", ["run", "lint"] ++ extra(params)}
  defp command_argv("build", params), do: {"npm", ["run", "build"] ++ extra(params)}
  defp command_argv("install", params), do: {"npm", ["install"] ++ extra(params)}

  defp command_argv("format", params) do
    if package_script?(params, "format:check") do
      {"npm", ["run", "format:check"] ++ extra(params)}
    else
      {"npm", ["run", "format", "--", "--check"] ++ extra(params)}
    end
  end

  defp command_argv("npx-playwright-test", params),
    do: {"npx", ["playwright", "test"] ++ extra(params)}

  defp command_argv("npx-playwright-show-report", params),
    do: {"npx", ["playwright", "show-report"] ++ extra(params)}

  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))

  defp classification("install"), do: ["network", "mutating"]
  defp classification(_command), do: []

  defp package_script?(params, script) do
    workdir = Map.get(params, "workdir", ".")

    with {:ok, safe_workdir} <- PathSafety.resolve(workdir),
         {:ok, content} <- File.read(Path.join(safe_workdir, "package.json")),
         {:ok, decoded} <- Jason.decode(content) do
      decoded |> get_in(["scripts", script]) |> is_binary()
    else
      _ -> false
    end
  end
end
