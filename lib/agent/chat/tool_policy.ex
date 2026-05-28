defmodule Beamcore.Agent.Chat.ToolPolicy do
  @moduledoc """
  Runtime tool policy derived from an explicit Policy block.

  Natural-language task text is intentionally not used for mutation or network
  intent detection. If a Policy block is present, it is the source of truth.
  Without a Policy block, the default is autonomous mode. Hard path safety and
  project policy still apply at runtime.
  """

  alias Beamcore.Agent.Tools.PathSafety
  alias Beamcore.Agent.Policy.ProjectPolicy

  @type mode ::
          :unrestricted
          | :unconfirmed
          | :development
          | :read_only
          | :restricted_write
          | :invalid_policy
  @type t :: %{
          mode: mode(),
          allow_task: boolean(),
          allow_network: boolean(),
          allowed_write_paths: [binary()],
          allowed_tools: [binary()] | nil,
          blocked_tools: [binary()],
          project_policy_bypassed?: boolean()
        }

  @read_only_tools ~w(read grep glob tree git mix memory)
  @unconfirmed_tools ~w(read grep glob tree plan git memory)
  @restricted_write_tools ~w(read grep glob write edit patch fs mix memory)
  @development_tools ~w(read grep glob edit patch write tree git fs mix memory python node make go rust terraform ruby bazel)
  @all_tool_names ~w(read grep glob edit patch write web_get tree git fs task mix plan image_generation memory python node make go rust terraform ruby bazel)
  @mutation_tools ~w(write edit patch fs image_generation)
  @read_only_git_operations ~w(status diff log)
  @read_only_mix_commands ~w(test compile validate)
  @valid_modes ~w(read_only development restricted_write)

  @doc """
  Build a policy from the latest complete user message.
  """
  @spec from_user_message(binary()) :: t()
  def from_user_message(content) when is_binary(content) do
    content
    |> parse_policy_block()
    |> policy_from_block()
  end

  def from_user_message(_content), do: default()

  @doc """
  Permissive policy for trusted sessions. Allows all tools and paths.
  """
  @spec yolo() :: t()
  @spec yolo(keyword()) :: t()
  def yolo(opts \\ []) do
    %{
      mode: :unrestricted,
      allow_task: true,
      allow_network: true,
      allowed_write_paths: ["**/*"],
      allowed_tools: nil,
      blocked_tools: [],
      project_policy_bypassed?: Keyword.get(opts, :project_policy_bypassed?, false)
    }
  end

  @doc """
  Default policy for fresh interactive sessions and direct tool calls.
  """
  @spec default() :: t()
  def default, do: yolo()

  @doc """
  Policy used inside sub-agents. Nested task delegation is always disabled.
  """
  @spec subagent(binary()) :: t()
  def subagent(prompt) do
    prompt
    |> from_user_message()
    |> Map.put(:allow_task, false)
    |> Map.update(:blocked_tools, ["task"], &Enum.uniq(["task" | &1]))
  end

  @doc """
  Returns the allowed tool names for the given policy.
  """
  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(policy),
    do: policy |> base_allowed_tool_names() |> apply_project_tool_filters(policy)

  @doc """
  Enforce the policy for a concrete tool call.
  """
  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(policy, name, args \\ %{}) do
    project_policy = ProjectPolicy.load()

    cond do
      name not in base_allowed_tool_names(policy) ->
        {:error, blocked_message(policy, name)}

      not project_policy_bypassed?(policy) and
          project_blocked?(project_policy, policy, name, args) ->
        project_blocked_message(project_policy, policy, name, args)

      confirmation_required?(policy) and name in @mutation_tools ->
        {:error, mutation_confirmation_message()}

      fail_closed?(policy) and name == "git" ->
        allow_read_only_git(args)

      fail_closed?(policy) and name == "mix" ->
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

  @spec confirmation_required?(t()) :: boolean()
  def confirmation_required?(%{mode: :unconfirmed}), do: true
  def confirmation_required?(_policy), do: false

  @spec invalid_policy?(t()) :: boolean()
  def invalid_policy?(%{mode: :invalid_policy}), do: true
  def invalid_policy?(_policy), do: false

  @spec restricted_write?(t()) :: boolean()
  def restricted_write?(%{mode: :restricted_write}), do: true
  def restricted_write?(_policy), do: false

  @spec project_policy_bypassed?(t()) :: boolean()
  def project_policy_bypassed?(policy), do: Map.get(policy, :project_policy_bypassed?, false)

  defp fail_closed?(policy),
    do: read_only?(policy) or invalid_policy?(policy) or confirmation_required?(policy)

  @doc """
  Build a one-turn restricted-write policy for legacy compatibility and tests.
  """
  @spec restricted_write_policy([binary()], [binary()]) :: t()
  def restricted_write_policy(allowed_write_paths, allowed_tools) do
    allowed_tools = allowed_tools |> Enum.uniq()

    %{
      mode: :restricted_write,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: Enum.uniq(allowed_write_paths),
      allowed_tools: allowed_tools,
      blocked_tools: ["task", "web_get", "git"],
      project_policy_bypassed?: false
    }
  end

  defp policy_from_block(nil), do: default()

  defp policy_from_block(block) do
    mode = parse_mode(Map.get(block, "mode"))
    allowed_tools = parse_tools(Map.get(block, "allowed_tools"))
    blocked_tools = parse_tools(Map.get(block, "blocked_tools")) || []
    allowed_write_paths = parse_paths(Map.get(block, "allowed_write_paths"))

    %{
      mode: mode,
      allow_task: tool_enabled?("task", allowed_tools, blocked_tools),
      allow_network: tool_enabled?("web_get", allowed_tools, blocked_tools),
      allowed_write_paths: allowed_write_paths,
      allowed_tools: allowed_tools,
      blocked_tools: blocked_tools,
      project_policy_bypassed?: false
    }
  end

  defp parse_mode([mode | _rest]), do: parse_mode(mode)
  defp parse_mode(mode) when mode in @valid_modes, do: String.to_atom(mode)
  defp parse_mode(_mode), do: :invalid_policy

  defp parse_tools(nil), do: nil

  defp parse_tools(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> Enum.filter(&(&1 in @all_tool_names))
    |> Enum.uniq()
  end

  defp parse_paths(nil), do: []

  defp parse_paths(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> Enum.map(&normalize_candidate_path/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp split_values(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tool_enabled?(tool, allowed_tools, blocked_tools) do
    tool in (allowed_tools || []) and tool not in blocked_tools
  end

  defp explicit_tool_enabled?(policy, tool) do
    tool in (Map.get(policy, :allowed_tools) || []) and
      tool not in Map.get(policy, :blocked_tools, [])
  end

  defp parse_policy_block(content) do
    lines = String.split(content, ~r/\R/)

    case Enum.split_while(lines, &(String.trim(&1) != "Policy:")) do
      {_before, []} -> nil
      {_before, [_policy | rest]} -> parse_policy_lines(rest)
    end
  end

  defp parse_policy_lines(lines) do
    {_current_key, data} =
      Enum.reduce_while(lines, {nil, %{}}, fn line, {current_key, data} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            {:cont, {current_key, data}}

          String.starts_with?(trimmed, "- ") and current_key ->
            value = trimmed |> String.trim_leading("- ") |> String.trim()
            {:cont, {current_key, Map.update(data, current_key, [value], &(&1 ++ [value]))}}

          String.contains?(trimmed, ":") ->
            [key, value] = String.split(trimmed, ":", parts: 2)
            key = String.trim(key)
            value = String.trim(value)

            if valid_key?(key) do
              data = Map.put_new(data, key, [])
              data = if value == "", do: data, else: Map.put(data, key, [value])
              {:cont, {key, data}}
            else
              {:halt, {current_key, data}}
            end

          true ->
            {:halt, {current_key, data}}
        end
      end)

    data
  end

  defp valid_key?(key), do: key in ~w(mode allowed_tools blocked_tools allowed_write_paths)

  defp maybe_add(tools, tool, true), do: tools ++ [tool]
  defp maybe_add(tools, _tool, false), do: tools

  defp apply_tool_filters(tools, policy) do
    tools
    |> filter_allowed_tools(Map.get(policy, :allowed_tools))
    |> Enum.reject(&(&1 in Map.get(policy, :blocked_tools, [])))
  end

  defp apply_project_tool_filters(tools, policy) do
    if project_policy_bypassed?(policy) do
      tools
    else
      ProjectPolicy.allowed_tool_names(tools, policy, ProjectPolicy.load())
    end
  end

  defp base_allowed_tool_names(%{mode: :unrestricted} = policy),
    do: apply_tool_filters(@all_tool_names, policy)

  defp base_allowed_tool_names(%{mode: :unconfirmed} = policy),
    do: apply_tool_filters(@unconfirmed_tools, policy)

  defp base_allowed_tool_names(%{mode: :invalid_policy} = policy),
    do: apply_tool_filters(@read_only_tools, policy)

  defp base_allowed_tool_names(%{mode: :read_only} = policy),
    do: apply_tool_filters(@read_only_tools, policy)

  defp base_allowed_tool_names(%{mode: :restricted_write} = policy) do
    @restricted_write_tools
    |> maybe_add("task", Map.get(policy, :allow_task, false))
    |> maybe_add("web_get", Map.get(policy, :allow_network, false))
    |> maybe_add("image_generation", explicit_tool_enabled?(policy, "image_generation"))
    |> apply_tool_filters(policy)
  end

  defp base_allowed_tool_names(%{mode: :development} = policy) do
    @development_tools
    |> maybe_add("task", Map.get(policy, :allow_task, false))
    |> maybe_add("web_get", Map.get(policy, :allow_network, false))
    |> maybe_add("image_generation", explicit_tool_enabled?(policy, "image_generation"))
    |> apply_tool_filters(policy)
  end

  defp filter_allowed_tools(tools, nil), do: tools
  defp filter_allowed_tools(tools, allowed_tools), do: Enum.filter(tools, &(&1 in allowed_tools))

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

  defp allow_restricted_write(policy, name, args) do
    case name do
      "write" -> allow_exact_path(policy, Map.get(args, "filePath") || Map.get(args, "path"))
      "edit" -> allow_exact_path(policy, Map.get(args, "path"))
      "patch" -> allow_patch(policy, Map.get(args, "patch_content"))
      "fs" -> allow_restricted_fs(policy, args)
      "image_generation" -> allow_exact_path(policy, Map.get(args, "output_path"))
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
      policy
      |> Map.get(:allowed_write_paths, [])
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    if normalized in allowed_parents do
      :ok
    else
      {:error, restricted_path_message(policy, normalized || path)}
    end
  end

  defp blocked_message(%{mode: :read_only}, name) do
    "Tool call blocked by read-only policy: #{name}."
  end

  defp blocked_message(%{mode: :unconfirmed}, name) when name in @mutation_tools do
    mutation_confirmation_message()
  end

  defp blocked_message(%{mode: :unconfirmed}, name) do
    "Tool call blocked by legacy unconfirmed policy: #{name}. Mutation tools are unavailable in this mode."
  end

  defp blocked_message(%{mode: :invalid_policy}, name) do
    "Tool call blocked by invalid policy: #{name}. The Policy block has an invalid mode, so mutation tools are disabled."
  end

  defp blocked_message(%{mode: :restricted_write}, name) do
    "Tool call blocked by restricted-write policy: #{name}. Only explicitly allowed file writes are permitted."
  end

  defp blocked_message(_policy, name), do: "Tool call blocked by policy: #{name}."

  defp project_blocked?(project_policy, policy, name, args) do
    case ProjectPolicy.allow_tool_call(project_policy, policy, name, args) do
      :ok -> false
      {:error, _message} -> true
    end
  end

  defp project_blocked_message(project_policy, policy, name, args) do
    case ProjectPolicy.allow_tool_call(project_policy, policy, name, args) do
      {:error, message} -> {:error, message}
      :ok -> {:error, "Tool call blocked by project policy: #{name}."}
    end
  end

  defp restricted_path_message(policy, path) do
    "Tool call blocked by restricted-write policy: #{path} is not in allowed_write_paths. Allowed write paths: #{Enum.join(Map.get(policy, :allowed_write_paths, []), ", ")}."
  end

  defp mutation_confirmation_message do
    "Mutation tools are unavailable in legacy unconfirmed policy."
  end

  defp normalize_candidate_path(path) do
    path = path |> String.trim() |> String.trim_trailing(".") |> String.trim_trailing(",")

    case PathSafety.resolve(path, allow_missing: true) do
      {:ok, absolute_path} -> Path.relative_to(absolute_path, PathSafety.workspace_root())
      {:error, _reason} -> nil
    end
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
