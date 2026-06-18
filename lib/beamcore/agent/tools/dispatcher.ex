defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

  @tools [
    Beamcore.Agent.Tools.Eeva
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args) do
    case find_tool(name) do
      nil ->
        "Function not implemented"

      tool ->
        execute_tool(tool, name, args)
    end
  end

  @doc """
  Get the list of tool specs for API calls.
  """
  def tool_specs do
    Enum.map(@tools, fn tool -> tool.spec() end)
  end

  defp execute_tool(tool, name, args) do
    try do
      tool.execute(args)
    rescue
      e ->
        Beamcore.AppLog.exception(:error, e, __STACKTRACE__, tool: name)

        "Tool call failed, but the session is still active. " <>
          "Error executing tool #{name}: #{inspect(e)}. " <>
          "Details were written to #{Beamcore.AppLog.log_path()}. " <>
          "Inspect the error, adjust the approach, and retry or choose another path."
    end
  end

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end
end
