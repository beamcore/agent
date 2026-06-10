defmodule Beamcore.Agent.Tools.Dispatcher do
  @moduledoc """
  Dynamically resolves and executes tools.
  """

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Policy.ProjectPolicy

  @tools [
    Beamcore.Agent.Tools.Eeva
  ]

  @doc """
  Execute a tool by name with the given arguments.
  """
  def execute(name, args, policy \\ ToolPolicy.default()) do
    start_time = System.monotonic_time(:millisecond)
    {org, repo} = Beamcore.Ledger.detect_org_repo()

    {name, args} = normalize_tool_call(name, args)

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
                ProjectPolicy.with_bypass(fn -> execute_tool(tool, name, args, policy) end)
              else
                execute_tool(tool, name, args, policy)
              end

            duration = System.monotonic_time(:millisecond) - start_time

            status = tool_result_status(result)

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

  defp execute_tool(tool, name, args, policy) do
    previous_policy = Process.get(:beamcore_tool_policy)
    Process.put(:beamcore_tool_policy, policy)

    try do
      if function_exported?(tool, :execute, 2) do
        tool.execute(args, policy)
      else
        tool.execute(args)
      end
    rescue
      e -> "Error executing tool #{name}: #{inspect(e)}"
    after
      if previous_policy do
        Process.put(:beamcore_tool_policy, previous_policy)
      else
        Process.delete(:beamcore_tool_policy)
      end
    end
  end

  defp tool_result_status(result) when is_binary(result) do
    cond do
      String.starts_with?(String.trim_leading(result), "Error:") ->
        :error

      true ->
        case Jason.decode(result) do
          {:ok, %{"ok" => false}} -> :error
          _ -> :ok
        end
    end
  end

  defp tool_result_status(_result), do: :ok

  defp find_tool(name) do
    Enum.find(@tools, fn tool ->
      tool.name() == name
    end)
  end

  @doc false
  def normalize_tool_call(name, args), do: {name, args}
end
