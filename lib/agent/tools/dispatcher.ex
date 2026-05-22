defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

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
    Beamcore.Agent.Tools.Mix
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args) do
    case find_tool(name) do
      nil ->
        "Function not implemented"

      tool ->
        try do
          tool.execute(args)
        rescue
          e -> "Error executing tool #{name}: #{inspect(e)}"
        end
    end
  end

  @doc """
  Get the list of tool specs for API calls.
  """
  def tool_specs() do
    Enum.map(@tools, fn tool -> tool.spec() end)
  end

  @conductor_tools [
    Beamcore.Agent.Tools.Task,
    Beamcore.Agent.Tools.Git,
    Beamcore.Agent.Tools.Tree,
    Beamcore.Agent.Tools.Read
  ]

  @doc """
  Get the list of conductor tool specs for main loop API calls.
  """
  def conductor_tool_specs() do
    Enum.map(@conductor_tools, fn tool -> tool.spec() end)
  end

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end
end
