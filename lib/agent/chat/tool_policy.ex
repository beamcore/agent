defmodule Beamcore.Agent.Chat.ToolPolicy do
  @moduledoc """
  Runtime policy for the single Eeva execution surface.

  BeamCore exposes exactly one model-facing tool: `eeva`.

  The model writes ordinary Elixir code, while lower runtime layers inspect and
  guard its actual effects: filesystem access, commands, network calls, memory
  mutations, and other capabilities.

  Permitted operations execute autonomously. Policy violations are rejected
  programmatically and never create a user confirmation loop.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy

  @tool "eeva"

  @valid_modes ~w(
    read_only
    development
    restricted_write
  )

  @type mode ::
          :unrestricted
          | :development
          | :read_only
          | :restricted_write
          | :local_context_helper
          | :invalid_policy
          | :chat
          | :research

  @type t :: %{
          mode: mode(),
          allow_task: boolean(),
          allow_network: boolean(),
          allowed_write_paths: [binary()],
          allowed_tools: [binary()] | nil,
          blocked_tools: [binary()],
          allow_memory_read: boolean(),
          allow_memory_write: boolean(),
          project_policy_bypassed?: boolean()
        }

  @doc """
  Builds a runtime policy from the final `Policy:` block in a user message.

  When no explicit block exists, BeamCore uses autonomous unrestricted mode.
  """
  @spec from_user_message(binary()) :: t()
  def from_user_message(content) when is_binary(content) do
    case parse_policy_block(content) do
      nil -> default()
      block -> policy_from_block(block)
    end
  end

  def from_user_message(_content), do: default()

  @doc """
  Fully autonomous execution policy.

  Hard runtime boundaries and project policy still apply unless
  `project_policy_bypassed?` is explicitly enabled by trusted application code.
  """
  @spec yolo(keyword()) :: t()
  def yolo(opts \\ []) do
    %{
      mode: :unrestricted,
      allow_task: false,
      allow_network: true,
      allowed_write_paths: ["**/*"],
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: true,
      project_policy_bypassed?: Keyword.get(opts, :project_policy_bypassed?, false)
    }
  end

  @doc """
  Default autonomous BeamCore policy.
  """
  @spec default() :: t()
  def default, do: yolo()

  @doc """
  F2 Chat exposes Eeva only for safe in-process work such as memory access.
  Filesystem and command access remain blocked by the Eeva runtime policy.
  """
  @spec chat() :: t()
  def chat do
    %{
      mode: :chat,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: [],
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: true,
      project_policy_bypassed?: false
    }
  end

  @doc """
  F3 Research exposes Eeva and limits writes to Markdown research artifacts.

  The actual path and effect checks are performed by the Eeva policy analyzer
  and runtime guards.
  """
  @spec research() :: t()
  def research do
    %{
      mode: :research,
      allow_task: false,
      allow_network: true,
      allowed_write_paths: ["**/*.md", "research_index.md"],
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: true,
      project_policy_bypassed?: false
    }
  end

  @doc """
  Builds the policy inherited by an internal sub-agent.

  `allow_task` remains in the map for compatibility with session and persisted
  policy structures. It does not expose a separate task tool.
  """
  @spec subagent(binary()) :: t()
  def subagent(prompt), do: from_user_message(prompt)

  @doc """
  Read-only Eeva policy for an optional local context helper.
  """
  @spec local_context_helper(t()) :: t()
  def local_context_helper(parent_policy \\ default()) do
    %{
      mode: :local_context_helper,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: [],
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: false,
      project_policy_bypassed?: project_policy_bypassed?(parent_policy)
    }
  end

  @doc """
  Creates a one-turn restricted-write policy.

  The second argument is retained for compatibility with older callers. Since
  Eeva is the only tool, old tool-name lists are intentionally ignored.
  """
  @spec restricted_write_policy([binary()], [binary()]) :: t()
  def restricted_write_policy(allowed_write_paths, _legacy_allowed_tools) do
    %{
      mode: :restricted_write,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: normalize_paths(allowed_write_paths),
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: true,
      project_policy_bypassed?: false
    }
  end

  @doc """
  Returns the model-facing tools permitted by the runtime and project policies.

  The result can only be `[]` or `["eeva"]`.
  """
  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(policy) when is_map(policy) do
    policy
    |> runtime_allowed_tool_names()
    |> apply_project_policy(policy)
  end

  @doc """
  Authorizes an external model tool call.

  This only authorizes entry into Eeva. Filesystem, command, network, memory,
  and other effects inside the submitted Elixir program must still be checked
  by Eeva's AST analyzer and runtime guards.
  """
  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(policy, name, args \\ %{})

  def allow_tool_call(%{mode: :invalid_policy}, @tool, _args) do
    {:error, "Eeva execution is blocked because the Policy block is invalid."}
  end

  def allow_tool_call(policy, @tool, args) when is_map(policy) and is_map(args) do
    cond do
      @tool not in allowed_tool_names(policy) ->
        {:error, "Eeva execution is blocked by the active policy."}

      project_policy_bypassed?(policy) ->
        :ok

      true ->
        ProjectPolicy.allow_tool_call(
          ProjectPolicy.load(),
          policy,
          @tool,
          args
        )
    end
  end

  def allow_tool_call(_policy, name, _args) do
    {:error, "Unknown tool #{inspect(name)}. BeamCore exposes only eeva."}
  end

  @doc """
  BeamCore never enters a confirmation loop for normal Eeva operations.
  """
  @spec confirmation_required?(t()) :: boolean()
  def confirmation_required?(_policy), do: false

  @spec project_policy_bypassed?(t()) :: boolean()
  def project_policy_bypassed?(policy) when is_map(policy) do
    Map.get(policy, :project_policy_bypassed?, false)
  end

  def project_policy_bypassed?(_policy), do: false

  @spec read_only?(t()) :: boolean()
  def read_only?(%{mode: :read_only}), do: true
  def read_only?(_policy), do: false

  @spec invalid_policy?(t()) :: boolean()
  def invalid_policy?(%{mode: :invalid_policy}), do: true
  def invalid_policy?(_policy), do: false

  @spec restricted_write?(t()) :: boolean()
  def restricted_write?(%{mode: :restricted_write}), do: true
  def restricted_write?(_policy), do: false

  @spec local_context_helper?(t()) :: boolean()
  def local_context_helper?(%{mode: :local_context_helper}), do: true
  def local_context_helper?(_policy), do: false

  @spec research?(t()) :: boolean()
  def research?(%{mode: :research}), do: true
  def research?(_policy), do: false

  @spec network_allowed?(t()) :: boolean()
  def network_allowed?(policy) when is_map(policy) do
    Map.get(policy, :allow_network, false)
  end

  def network_allowed?(_policy), do: false

  @spec write_allowed?(t()) :: boolean()
  def write_allowed?(%{mode: mode})
      when mode in [:unrestricted, :development, :restricted_write, :research],
      do: true

  def write_allowed?(_policy), do: false

  defp runtime_allowed_tool_names(%{mode: :invalid_policy}), do: []

  defp runtime_allowed_tool_names(policy) do
    allowed_tools = Map.get(policy, :allowed_tools)
    blocked_tools = Map.get(policy, :blocked_tools, [])

    cond do
      @tool in blocked_tools ->
        []

      is_list(allowed_tools) and @tool not in allowed_tools ->
        []

      true ->
        [@tool]
    end
  end

  defp apply_project_policy([], _policy), do: []

  defp apply_project_policy(names, policy) do
    if project_policy_bypassed?(policy) do
      names
    else
      ProjectPolicy.allowed_tool_names(
        names,
        policy,
        ProjectPolicy.load()
      )
    end
  end

  defp policy_from_block(block) when is_map(block) do
    mode = parse_mode(first(block["mode"]))
    allowed_tools = parse_tools(block["allowed_tools"])
    blocked_tools = parse_tools(block["blocked_tools"]) || []
    explicit_write_paths = parse_paths(block["allowed_write_paths"])

    %{
      mode: mode,
      allow_task: false,
      allow_network: parse_boolean(first(block["allow_network"]), false),
      allowed_write_paths: write_paths_for_mode(mode, explicit_write_paths),
      allowed_tools: allowed_tools,
      blocked_tools: blocked_tools,
      allow_memory_read: true,
      allow_memory_write: memory_write_for_mode(mode),
      project_policy_bypassed?: false
    }
  end

  defp memory_write_for_mode(mode), do: mode not in [:invalid_policy, :local_context_helper]

  defp write_paths_for_mode(:development, []), do: ["**/*"]
  defp write_paths_for_mode(:unrestricted, []), do: ["**/*"]
  defp write_paths_for_mode(:read_only, _paths), do: []
  defp write_paths_for_mode(:local_context_helper, _paths), do: []
  defp write_paths_for_mode(:invalid_policy, _paths), do: []
  defp write_paths_for_mode(_mode, paths), do: paths

  defp parse_mode(mode) when mode in @valid_modes do
    String.to_existing_atom(mode)
  end

  defp parse_mode(_mode), do: :invalid_policy

  defp parse_boolean(value, _default)
       when value in [true, "true", "yes", "on", "1"],
       do: true

  defp parse_boolean(value, _default)
       when value in [false, "false", "no", "off", "0"],
       do: false

  defp parse_boolean(_value, default), do: default

  defp parse_tools(nil), do: nil

  defp parse_tools(values) when is_list(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> Enum.filter(&(&1 == @tool))
    |> Enum.uniq()
  end

  defp parse_tools(value), do: parse_tools([value])

  defp parse_paths(nil), do: []

  defp parse_paths(values) when is_list(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> normalize_paths()
  end

  defp parse_paths(value), do: parse_paths([value])

  defp normalize_paths(paths) do
    paths
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_values(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  defp first([value | _rest]), do: value
  defp first(value), do: value

  defp parse_policy_block(content) do
    content
    |> String.split(~r/\R/)
    |> find_last_policy_block()
  end

  defp find_last_policy_block(lines) do
    policy_indexes =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _index} ->
        String.trim(line) == "Policy:"
      end)
      |> Enum.map(&elem(&1, 1))

    case List.last(policy_indexes) do
      nil ->
        nil

      index ->
        lines
        |> Enum.drop(index + 1)
        |> parse_policy_lines()
    end
  end

  defp parse_policy_lines(lines) do
    {_current_key, data} =
      Enum.reduce_while(lines, {nil, %{}}, fn line, {current_key, data} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            {:cont, {current_key, data}}

          String.starts_with?(trimmed, "- ") and is_binary(current_key) ->
            value =
              trimmed
              |> String.trim_leading("- ")
              |> String.trim()

            updated =
              Map.update(
                data,
                current_key,
                [value],
                &(&1 ++ [value])
              )

            {:cont, {current_key, updated}}

          String.contains?(trimmed, ":") ->
            parse_policy_key_value(trimmed, current_key, data)

          true ->
            {:halt, {current_key, data}}
        end
      end)

    data
  end

  defp parse_policy_key_value(line, current_key, data) do
    [key, value] = String.split(line, ":", parts: 2)
    key = String.trim(key)
    value = String.trim(value)

    if valid_policy_key?(key) do
      updated =
        if value == "" do
          Map.put_new(data, key, [])
        else
          Map.put(data, key, [value])
        end

      {:cont, {key, updated}}
    else
      {:halt, {current_key, data}}
    end
  end

  defp valid_policy_key?(key) do
    key in ~w(
      mode
      allowed_tools
      blocked_tools
      allowed_write_paths
      allow_network
    )
  end
end
