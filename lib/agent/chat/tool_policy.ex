defmodule Beamcore.Agent.Chat.ToolPolicy do
  @moduledoc """
  Runtime policy for the single Eeva execution surface.

  BeamCore no longer exposes separate read, write, search, command, Git, test,
  task, plan, memory, or image tools to the model. A policy therefore decides
  only whether the `eeva` evaluator is available and whether its process may use
  network access. Normal permitted execution is autonomous and never enters an
  approval loop.
  """

  alias Beamcore.Agent.Policy.ProjectPolicy

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
          project_policy_bypassed?: boolean()
        }

  @tool "eeva"
  @valid_modes ~w(read_only development restricted_write)

  @spec from_user_message(binary()) :: t()
  def from_user_message(content) when is_binary(content) do
    case parse_policy_block(content) do
      nil -> default()
      block -> policy_from_block(block)
    end
  end

  def from_user_message(_content), do: default()

  @spec yolo(keyword()) :: t()
  def yolo(opts \\ []) do
    %{
      mode: :unrestricted,
      allow_task: false,
      allow_network: true,
      allowed_write_paths: ["**/*"],
      allowed_tools: [@tool],
      blocked_tools: [],
      project_policy_bypassed?: Keyword.get(opts, :project_policy_bypassed?, false)
    }
  end

  @spec default() :: t()
  def default, do: yolo()

  @spec chat() :: t()
  def chat do
    %{
      mode: :chat,
      allow_task: false,
      allow_network: true,
      allowed_write_paths: [],
      allowed_tools: [],
      blocked_tools: [@tool],
      project_policy_bypassed?: false
    }
  end

  @spec research() :: t()
  def research do
    %{
      mode: :research,
      allow_task: false,
      allow_network: true,
      allowed_write_paths: ["**/*"],
      allowed_tools: [@tool],
      blocked_tools: [],
      project_policy_bypassed?: false
    }
  end

  @spec subagent(binary()) :: t()
  def subagent(prompt), do: from_user_message(prompt)

  @spec local_context_helper(t()) :: t()
  def local_context_helper(parent_policy \\ default()) do
    %{
      mode: :local_context_helper,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: [],
      allowed_tools: [@tool],
      blocked_tools: [],
      project_policy_bypassed?: project_policy_bypassed?(parent_policy)
    }
  end

  @spec restricted_write_policy([binary()], [binary()]) :: t()
  def restricted_write_policy(allowed_write_paths, _allowed_tools) do
    %{
      mode: :restricted_write,
      allow_task: false,
      allow_network: false,
      allowed_write_paths: Enum.uniq(allowed_write_paths),
      allowed_tools: [@tool],
      blocked_tools: [],
      project_policy_bypassed?: false
    }
  end

  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(policy) do
    names =
      cond do
        policy.mode == :chat -> []
        @tool in Map.get(policy, :blocked_tools, []) -> []
        is_list(policy.allowed_tools) and @tool not in policy.allowed_tools -> []
        true -> [@tool]
      end

    if project_policy_bypassed?(policy) do
      names
    else
      ProjectPolicy.allowed_tool_names(names, policy, ProjectPolicy.load())
    end
  end

  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(policy, @tool, args \\ %{}) when is_map(args) do
    cond do
      @tool not in allowed_tool_names(policy) ->
        {:error, "Eeva execution is blocked by the active policy."}

      project_policy_bypassed?(policy) ->
        :ok

      true ->
        ProjectPolicy.allow_tool_call(ProjectPolicy.load(), policy, @tool, args)
    end
  end

  def allow_tool_call(_policy, name, _args),
    do: {:error, "Unknown tool #{name}. BeamCore exposes only eeva."}

  @spec confirmation_required?(t()) :: boolean()
  def confirmation_required?(_policy), do: false

  @spec project_policy_bypassed?(t()) :: boolean()
  def project_policy_bypassed?(policy), do: Map.get(policy, :project_policy_bypassed?, false)

  @spec read_only?(t()) :: boolean()
  def read_only?(%{mode: :read_only}), do: true
  def read_only?(_), do: false

  @spec invalid_policy?(t()) :: boolean()
  def invalid_policy?(%{mode: :invalid_policy}), do: true
  def invalid_policy?(_), do: false

  @spec restricted_write?(t()) :: boolean()
  def restricted_write?(%{mode: :restricted_write}), do: true
  def restricted_write?(_), do: false

  @spec local_context_helper?(t()) :: boolean()
  def local_context_helper?(%{mode: :local_context_helper}), do: true
  def local_context_helper?(_), do: false

  @spec research?(t()) :: boolean()
  def research?(%{mode: :research}), do: true
  def research?(_), do: false

  defp policy_from_block(block) do
    mode = parse_mode(first(block["mode"]))
    allowed = parse_tools(block["allowed_tools"])
    blocked = parse_tools(block["blocked_tools"]) || []

    %{
      mode: mode,
      allow_task: false,
      allow_network: parse_boolean(first(block["allow_network"]), false),
      allowed_write_paths: parse_paths(block["allowed_write_paths"]),
      allowed_tools: allowed,
      blocked_tools: blocked,
      project_policy_bypassed?: false
    }
  end

  defp parse_mode(mode) when mode in @valid_modes, do: String.to_existing_atom(mode)
  defp parse_mode(_), do: :invalid_policy

  defp parse_boolean(value, _default) when value in [true, "true", "yes", "on", "1"], do: true
  defp parse_boolean(value, _default) when value in [false, "false", "no", "off", "0"], do: false
  defp parse_boolean(_, default), do: default

  defp parse_tools(nil), do: nil

  defp parse_tools(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> Enum.filter(&(&1 == @tool))
    |> Enum.uniq()
  end

  defp parse_paths(nil), do: []

  defp parse_paths(values) do
    values
    |> Enum.flat_map(&split_values/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp split_values(value),
    do: value |> to_string() |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp first([value | _]), do: value
  defp first(value), do: value

  defp parse_policy_block(content) do
    lines = String.split(content, ~r/\R/)

    case Enum.split_while(lines, &(String.trim(&1) != "Policy:")) do
      {_before, []} -> nil
      {_before, [_ | rest]} -> parse_policy_lines(rest)
    end
  end

  defp parse_policy_lines(lines) do
    {_key, data} =
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

            if key in ~w(mode allowed_tools blocked_tools allowed_write_paths allow_network) do
              value = String.trim(value)
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
end
