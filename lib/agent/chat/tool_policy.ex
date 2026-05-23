defmodule Beamcore.Agent.Chat.ToolPolicy do
  @moduledoc """
  Runtime tool policy derived from the latest user request.

  The system prompt guides the model, but this module enforces important
  boundaries in code so that read-only requests cannot be violated by an
  accidental tool call.
  """

  @type mode :: :normal | :read_only | :restricted_write
  @type t :: %{
          mode: mode(),
          allow_task: boolean(),
          allow_network: boolean(),
          allowed_write_paths: [binary()]
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
    "no deletion",
    "analyze only",
    "without changes"
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
  @restricted_write_tools ~w(read grep glob write edit patch fs mix)
  @normal_tools ~w(read grep glob edit patch write tree git fs mix)
  @task_tool "task"
  @read_only_git_operations ~w(status diff log)
  @read_only_mix_commands ~w(test compile validate)
  @path_pattern ~r/(?:`)?([A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)+(?:\.[A-Za-z0-9_.-]+)?)(?:`)?/

  @doc """
  Build a policy from the latest user message.
  """
  @spec from_user_message(binary()) :: t()
  def from_user_message(content) when is_binary(content) do
    normalized = String.downcase(content)
    read_only = contains_any?(normalized, @read_only_markers)
    task_requested = contains_any?(normalized, @task_markers)
    network_requested = contains_any?(normalized, @network_markers)
    allowed_write_paths = extract_allowed_write_paths(content)
    restricted_write = allowed_write_paths != [] and restricted_write_request?(normalized)

    %{
      mode: policy_mode(read_only, restricted_write),
      allow_task: task_requested and not read_only and not restricted_write,
      allow_network: network_requested and not read_only,
      allowed_write_paths: allowed_write_paths
    }
  end

  def from_user_message(_content), do: default()

  @doc """
  Default policy for non-interactive direct tool calls.
  """
  @spec default() :: t()
  def default,
    do: %{mode: :normal, allow_task: false, allow_network: false, allowed_write_paths: []}

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

  def allowed_tool_names(%{mode: :restricted_write} = policy) do
    @restricted_write_tools
    |> maybe_add(@task_tool, Map.get(policy, :allow_task, false))
    |> maybe_add("curl", Map.get(policy, :allow_network, false))
  end

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

      restricted_write?(policy) ->
        allow_restricted_write(policy, name, args)

      true ->
        :ok
    end
  end

  @spec read_only?(t()) :: boolean()
  def read_only?(%{mode: :read_only}), do: true
  def read_only?(_policy), do: false

  @spec restricted_write?(t()) :: boolean()
  def restricted_write?(%{mode: :restricted_write}), do: true
  def restricted_write?(_policy), do: false

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

  defp blocked_message(%{mode: :restricted_write}, name) do
    "Tool call blocked by restricted-write policy: #{name}. Only explicitly allowed file writes are permitted."
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

  defp policy_mode(_read_only, true), do: :restricted_write
  defp policy_mode(true, false), do: :read_only
  defp policy_mode(false, false), do: :normal

  defp restricted_write_request?(text) do
    String.contains?(text, "allowed files") or
      String.contains?(text, "create only") or
      String.contains?(text, "may create only") or
      String.contains?(text, "only these files") or
      String.contains?(text, "these files may be created") or
      String.contains?(text, "создать только") or
      String.contains?(text, "только")
  end

  @doc """
  Extract explicitly allowed workspace-relative write paths from a user request.
  """
  @spec extract_allowed_write_paths(binary()) :: [binary()]
  def extract_allowed_write_paths(content) when is_binary(content) do
    @path_pattern
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&normalize_candidate_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def extract_allowed_write_paths(_content), do: []

  defp normalize_candidate_path(path) do
    path = path |> String.trim() |> String.trim_trailing(".") |> String.trim_trailing(",")

    cond do
      Path.type(path) == :absolute -> nil
      ".." in Path.split(path) -> nil
      String.starts_with?(path, ".") -> nil
      path |> Path.split() |> List.first() |> String.contains?(".") -> nil
      true -> path |> Path.expand("/") |> Path.relative_to("/")
    end
  end

  defp allow_restricted_write(policy, name, args) do
    case name do
      "write" -> allow_exact_path(policy, Map.get(args, "filePath") || Map.get(args, "path"))
      "edit" -> allow_exact_path(policy, Map.get(args, "path"))
      "patch" -> allow_patch(policy, Map.get(args, "patch_content"))
      "fs" -> allow_restricted_fs(policy, args)
      "mix" -> :ok
      "read" -> :ok
      "grep" -> :ok
      "glob" -> :ok
      _ -> {:error, blocked_message(policy, name)}
    end
  end

  defp allow_exact_path(policy, path) do
    normalized = normalize_candidate_path(to_string(path || ""))

    if normalized in Map.get(policy, :allowed_write_paths, []) do
      :ok
    else
      {:error, restricted_path_message(policy, normalized || path)}
    end
  end

  defp allow_patch(_policy, nil),
    do: {:error, "Tool call blocked by restricted-write policy: patch_content is required."}

  defp allow_patch(policy, patch_content) when is_binary(patch_content) do
    patch_paths =
      patch_content
      |> String.split("\n")
      |> Enum.filter(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))
      |> Enum.map(&patch_line_path/1)
      |> Enum.reject(&(&1 in [nil, "/dev/null"]))
      |> Enum.map(&strip_patch_prefix/1)
      |> Enum.map(&normalize_candidate_path/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    blocked = Enum.reject(patch_paths, &(&1 in Map.get(policy, :allowed_write_paths, [])))

    cond do
      patch_paths == [] ->
        {:error, "Tool call blocked by restricted-write policy: no changed files found in patch."}

      blocked == [] ->
        :ok

      true ->
        {:error, restricted_path_message(policy, Enum.join(blocked, ", "))}
    end
  end

  defp allow_restricted_fs(policy, args) do
    operation = Map.get(args, "operation")
    path = Map.get(args, "path")

    case operation do
      "mkdir" ->
        allow_parent_dir(policy, path)

      "touch" ->
        allow_exact_path(policy, path)

      "stat" ->
        :ok

      "exist" ->
        :ok

      _ ->
        {:error,
         "Tool call blocked by restricted-write policy: fs #{inspect(operation)} is not allowed."}
    end
  end

  defp allow_parent_dir(policy, path) do
    normalized = normalize_candidate_path(to_string(path || ""))

    allowed_parents =
      policy |> Map.get(:allowed_write_paths, []) |> Enum.map(&Path.dirname/1) |> Enum.uniq()

    if normalized in allowed_parents do
      :ok
    else
      {:error, restricted_path_message(policy, normalized || path)}
    end
  end

  defp restricted_path_message(policy, path) do
    "Tool call blocked by restricted-write policy: #{path} is not in allowed_write_paths. Allowed write paths: #{Enum.join(Map.get(policy, :allowed_write_paths, []), ", ")}."
  end

  defp patch_line_path(line) do
    line
    |> String.split(~r/\s+/, parts: 3, trim: true)
    |> Enum.at(1)
  end

  defp strip_patch_prefix("a/" <> path), do: path
  defp strip_patch_prefix("b/" <> path), do: path
  defp strip_patch_prefix(path), do: path
end
