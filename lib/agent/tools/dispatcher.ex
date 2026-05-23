defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

  alias Beamcore.Agent.Chat.ToolPolicy

  @tools [
    Beamcore.Agent.Tools.Grep,
    Beamcore.Agent.Tools.Read,
    Beamcore.Agent.Tools.Glob,
    Beamcore.Agent.Tools.Edit,
    Beamcore.Agent.Tools.Patch,
    Beamcore.Agent.Tools.Write,
    Beamcore.Agent.Tools.Curl,
    Beamcore.Agent.Tools.Tree,
    Beamcore.Agent.Tools.Git,
    Beamcore.Agent.Tools.Fs,
    Beamcore.Agent.Tools.Task,
    Beamcore.Agent.Tools.Plan,
    Beamcore.Agent.Tools.ImageGeneration,
    Beamcore.Agent.Tools.Mix
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args, policy \\ ToolPolicy.default()) do
    case find_tool(name) do
      nil ->
        "Function not implemented"

      tool ->
        case ToolPolicy.allow_tool_call(policy, name, args) do
          :ok ->
            execute_tool(tool, name, args)

          {:error, message} ->
            "Error: #{message}"
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
