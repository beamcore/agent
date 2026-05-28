defmodule Beamcore.Agent.Tools.Ruby do
  @moduledoc """
  Allowlisted Ruby/Rails workflow tool.
  """

  alias Beamcore.Agent.Tools.{CommandRunner, PathSafety}

  @allowed_commands ~w(test rspec rubocop rails-test rails-routes rails-db-status)
  @description """
  Run allowlisted Ruby and Rails commands. Rails runner, db:drop, and db:migrate
  are intentionally not exposed.
  """

  def name, do: "ruby"

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
        workdir: Map.get(params, "workdir", ".")
      )
      |> CommandRunner.encode()
    else
      CommandRunner.disallowed(name(), command, @allowed_commands) |> CommandRunner.encode()
    end
  end

  defp command_argv("test", params) do
    if rails_project?(params) do
      {"bundle", ["exec", "rails", "test"] ++ extra(params)}
    else
      {"bundle", ["exec", "ruby", "test"] ++ extra(params)}
    end
  end

  defp command_argv("rspec", params), do: {"bundle", ["exec", "rspec"] ++ extra(params)}
  defp command_argv("rubocop", params), do: {"bundle", ["exec", "rubocop"] ++ extra(params)}

  defp command_argv("rails-test", params),
    do: {"bundle", ["exec", "rails", "test"] ++ extra(params)}

  defp command_argv("rails-routes", params),
    do: {"bundle", ["exec", "rails", "routes"] ++ extra(params)}

  defp command_argv("rails-db-status", params),
    do: {"bundle", ["exec", "rails", "db:migrate:status"] ++ extra(params)}

  defp extra(params), do: CommandRunner.split_args(Map.get(params, "args"))

  defp rails_project?(params) do
    workdir = Map.get(params, "workdir", ".")

    with {:ok, safe_workdir} <- PathSafety.resolve(workdir) do
      File.exists?(Path.join(safe_workdir, "config/application.rb")) or
        File.exists?(Path.join(safe_workdir, "bin/rails"))
    else
      _ -> false
    end
  end
end
