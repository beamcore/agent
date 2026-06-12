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
    {name, args} = normalize_tool_call(name, args)

    case find_tool(name) do
      nil ->
        "Function not implemented"

      tool ->
        case ToolRuntime.allow_tool_call(caps, name, args) do
          :ok ->
            execute_tool(tool, name, args, caps)

          {:error, message} ->
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

  @doc """
  Get the list of conductor tool specs for main loop API calls.
  """
  def conductor_tool_specs(caps \\ ToolRuntime.default()) do
    tool_specs(caps)
  end

  @doc false
  def registered_tool_names do
    Enum.map(@tools, & &1.name())
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
      e -> "Error executing tool #{name}: #{inspect(e)}"
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

  @doc false
  def normalize_tool_call(name, args), do: {name, args}
end
