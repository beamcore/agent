defmodule Beamcore.Agent.Chat.ToolPolicy do
  @moduledoc """
  Runtime tool policy derived from the latest user request.

  The system prompt guides the model, but this module enforces important
  boundaries in code so that read-only requests cannot be violated by an
  accidental tool call.
  """

  @type mode :: :normal | :read_only
  @type t :: %{
          mode: mode(),
          allow_task: boolean(),
          allow_network: boolean()
        }

  @read_only_markers [
    "read-only",
    "readonly",
    "do not modify",
    "don't modify",
    "do not edit",
    "don't edit",
    "do not write",
    "don't write",
    "do not create",
    "don't create",
    "do not delete",
    "don't delete",
    "no file modifications",
    "no modifications",
    "no writes",
    "no edits",
    "no creation",
    "no deletion"
  ]

  @task_markers [
    "use task",
    "use the task tool",
    "sub-agent",
    "subagent",
    "delegate",
    "delegation",
    "parallel agents"
  ]

  @network_markers [
    "curl",
    "external url",
    "external urls",
    "fetch url",
    "fetch external",
    "http://",
    "https://"
  ]

  @read_only_tools ~w(read grep glob tree git mix)
  @normal_tools ~w(read grep glob edit patch write tree git fs mix)
  @task_tool "task"
  @read_only_git_operations ~w(status diff log)
  @read_only_mix_commands ~w(test compile validate)

  @doc """
  Build a policy from the latest user message.
  """
  @spec from_user_message(binary()) :: t()
  def from_user_message(content) when is_binary(content) do
    normalized = String.downcase(content)
    read_only = contains_any?(normalized, @read_only_markers)
    task_requested = contains_any?(normalized, @task_markers)
    network_requested = contains_any?(normalized, @network_markers)

    %{
      mode: if(read_only, do: :read_only, else: :normal),
      allow_task: task_requested and not read_only,
      allow_network: network_requested and not read_only
    }
  end

  def from_user_message(_content), do: default()

  @doc """
  Default policy for non-interactive direct tool calls.
  """
  @spec default() :: t()
  def default, do: %{mode: :normal, allow_task: false, allow_network: false}

  @doc """
  Policy used inside sub-agents. Nested task delegation is always disabled.
  """
  @spec subagent(binary()) :: t()
  def subagent(prompt) do
    prompt
    |> from_user_message()
    |> Map.put(:allow_task, false)
  end

  @doc """
  Returns the allowed tool names for the given policy.
  """
  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(%{mode: :read_only}), do: @read_only_tools

  def allowed_tool_names(%{mode: :normal} = policy) do
    @normal_tools
    |> maybe_add(@task_tool, Map.get(policy, :allow_task, false))
    |> maybe_add("curl", Map.get(policy, :allow_network, false))
  end

  @doc """
  Enforce the policy for a concrete tool call.
  """
  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(policy, name, args \\ %{}) do
    cond do
      name not in allowed_tool_names(policy) ->
        {:error, blocked_message(policy, name)}

      read_only?(policy) and name == "git" ->
        allow_read_only_git(args)

      read_only?(policy) and name == "mix" ->
        allow_read_only_mix(args)

      true ->
        :ok
    end
  end

  @spec read_only?(t()) :: boolean()
  def read_only?(%{mode: :read_only}), do: true
  def read_only?(_policy), do: false

  defp allow_read_only_git(args) do
    operation = Map.get(args, "operation") || Map.get(args, "command")

    if operation in @read_only_git_operations do
      :ok
    else
      {:error,
       "Tool call blocked by read-only policy: git operation #{inspect(operation)} is not allowed. Allowed git operations: #{Enum.join(@read_only_git_operations, ", ")}."}
    end
  end

  defp allow_read_only_mix(args) do
    command = Map.get(args, "command")

    if command in @read_only_mix_commands do
      :ok
    else
      {:error,
       "Tool call blocked by read-only policy: mix command #{inspect(command)} is not allowed. Allowed mix commands: #{Enum.join(@read_only_mix_commands, ", ")}."}
    end
  end

  defp blocked_message(%{mode: :read_only}, name) do
    "Tool call blocked by read-only policy: #{name}. The latest user request forbids file modifications, file creation, file deletion, task delegation, commits, pushes, and external network calls."
  end

  defp blocked_message(%{mode: :normal}, @task_tool) do
    "Tool call blocked: task delegation is disabled unless the user explicitly asks for task/sub-agent delegation. Use direct tools first."
  end

  defp blocked_message(%{mode: :normal}, "curl") do
    "Tool call blocked: external network access is disabled unless the user explicitly asks to fetch an external URL."
  end

  defp blocked_message(_policy, name), do: "Tool call blocked by policy: #{name}."

  defp maybe_add(tools, tool, true), do: tools ++ [tool]
  defp maybe_add(tools, _tool, false), do: tools

  defp contains_any?(text, markers), do: Enum.any?(markers, &String.contains?(text, &1))
end
