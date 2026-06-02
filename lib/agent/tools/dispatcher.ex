defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Policy.ProjectPolicy

  @tools [
    Beamcore.Agent.Tools.Grep,
    Beamcore.Agent.Tools.Read,
    Beamcore.Agent.Tools.Glob,
    Beamcore.Agent.Tools.Modify,
    Beamcore.Agent.Tools.WebGet,
    Beamcore.Agent.Tools.Tree,
    Beamcore.Agent.Tools.Git,
    Beamcore.Agent.Tools.Fs,
    Beamcore.Agent.Tools.Task,
    Beamcore.Agent.Tools.Plan,
    Beamcore.Agent.Tools.ImageGeneration,
    Beamcore.Agent.Tools.Mix,
    Beamcore.Agent.Tools.Memory,
    Beamcore.Agent.Tools.Python,
    Beamcore.Agent.Tools.Node,
    Beamcore.Agent.Tools.Make,
    Beamcore.Agent.Tools.Go,
    Beamcore.Agent.Tools.Rust,
    Beamcore.Agent.Tools.Terraform,
    Beamcore.Agent.Tools.Ruby,
    Beamcore.Agent.Tools.Bazel,
    Beamcore.Agent.Tools.Reflect
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args, policy \\ ToolPolicy.default()) do
    start_time = System.monotonic_time(:millisecond)
    {org, repo} = Beamcore.Ledger.detect_org_repo()

    case find_tool(name) do
      nil ->
        duration = System.monotonic_time(:millisecond) - start_time
        result = "Function not implemented"
        Beamcore.Ledger.log_action(org, repo, name, args, result, duration, 0, :error)
        result

      tool ->
        case ToolPolicy.allow_tool_call(policy, name, args) do
          :ok ->
            result =
              if ToolPolicy.project_policy_bypassed?(policy) do
                ProjectPolicy.with_bypass(fn -> execute_tool(tool, name, args) end)
              else
                execute_tool(tool, name, args)
              end

            duration = System.monotonic_time(:millisecond) - start_time

            status =
              if is_binary(result) and String.starts_with?(result, "Error:"),
                do: :error,
                else: :ok

            Beamcore.Ledger.log_action(org, repo, name, args, result, duration, 0, status)
            result

          {:error, message} ->
            duration = System.monotonic_time(:millisecond) - start_time
            result = "Error: #{message}"
            Beamcore.Ledger.log_action(org, repo, name, args, result, duration, 0, :error)
            result
        end
    end
  end

  @doc """
  Get the list of tool specs for API calls.
  """
  def tool_specs(policy \\ ToolPolicy.default()) do
    allowed_names = ToolPolicy.allowed_tool_names(policy)

    @tools
    |> Enum.filter(fn tool -> tool.name() in allowed_names end)
    |> Enum.map(fn tool -> tool.spec() end)
  end

  @doc """
  Get the list of conductor tool specs for main loop API calls.
  """
  def conductor_tool_specs(policy \\ ToolPolicy.default()) do
    tool_specs(policy)
  end

  @doc false
  def registered_tool_names do
    Enum.map(@tools, & &1.name())
  end

  defp execute_tool(tool, name, args) do
    try do
      tool.execute(args)
    rescue
      e -> "Error executing tool #{name}: #{inspect(e)}"
    end
  end

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end
end
