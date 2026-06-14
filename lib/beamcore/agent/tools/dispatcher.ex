defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

  alias Beamcore.Agent.Chat.ToolRuntime

  @tools [
    Beamcore.Agent.Tools.Eeva
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args, caps \\ ToolRuntime.default()) do
    case find_tool(name) do
      nil ->
        "Function not implemented"

      tool ->
        case ToolRuntime.allow_tool_call(caps, name, args) do
          :ok ->
            execute_tool(tool, name, args, caps)

          {:error, message} ->
            Beamcore.AppLog.warn("Tool call rejected", tool: name, reason: message)
            "Error: #{message}"
        end
    end
  end

  @doc """
  Get the list of tool specs for API calls.
  """
  def tool_specs(caps \\ ToolRuntime.default()) do
    allowed_names = ToolRuntime.allowed_tool_names(caps)

    @tools
    |> Enum.filter(fn tool -> tool.name() in allowed_names end)
    |> Enum.map(fn tool -> tool.spec() end)
  end

  defp execute_tool(tool, name, args, caps) do
    previous_caps = Process.get(:beamcore_tool_runtime)
    Process.put(:beamcore_tool_runtime, caps)

    try do
      if function_exported?(tool, :execute, 2) do
        tool.execute(args, caps)
      else
        tool.execute(args)
      end
    rescue
      e ->
        Beamcore.AppLog.exception(:error, e, __STACKTRACE__, tool: name)

        "Tool call failed, but the session is still active. " <>
          "Error executing tool #{name}: #{inspect(e)}. " <>
          "Details were written to #{Beamcore.AppLog.log_path()}. " <>
          "Inspect the error, adjust the approach, and retry or choose another path."
    after
      if previous_caps do
        Process.put(:beamcore_tool_runtime, previous_caps)
      else
        Process.delete(:beamcore_tool_runtime)
      end
    end
  end

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end
end
