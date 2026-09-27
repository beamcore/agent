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
        not_implemented(name)

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
    catch
      kind, reason ->
        Beamcore.AppLog.error("Tool call threw",
          tool: name,
          kind: kind,
          reason: inspect(reason)
        )

        "Tool call failed, but the session is still active. " <>
          "Error executing tool #{name} (#{kind}): #{inspect(reason)}. " <>
          "Inspect the error, adjust the approach, and retry or choose another path."
    end
  end

  # Unknown tools return the same structured shape as Eeva errors so the
  # model and the loop's failure guard treat them as failures, not results.
  # The "classification" field lets the loop's failure guard treat these
  # as failures; the message keeps the legacy wording for readability.
  defp not_implemented(name) do
    Jason.encode!(%{
      "ok" => false,
      "tool" => to_string(name),
      "exit_code" => nil,
      "stdout" => "",
      "stderr" => "Function not implemented: unknown tool #{inspect(name)}.",
      "result" => nil,
      "classification" => "not_implemented",
      "recoverable" => true,
      "session_active" => true,
      "next_step" =>
        "Use one of the exposed tools instead. Inspect the tool specs and retry with a supported tool.",
      "summary" => "Function not implemented: unknown tool #{inspect(name)}."
    })
  end

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end
end
