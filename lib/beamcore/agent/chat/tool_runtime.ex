defmodule Beamcore.Agent.Chat.ToolRuntime do
  @moduledoc """
  Runtime capabilities for the single Eeva execution surface.

  BeamCore exposes exactly one model-facing tool: `eeva`.

  The model writes ordinary Elixir code, while lower runtime layers inspect and
  guard its actual effects: filesystem access, commands, network calls, memory
  mutations, and other capabilities.

  Permitted operations execute autonomously. Hard safety violations are rejected
  programmatically and never create a user confirmation loop.
  """

  @tool "eeva"

  @type mode :: :yolo

  @type t :: %{
          mode: mode(),
          allow_task: boolean(),
          allow_network: boolean(),
          allowed_tools: [binary()] | nil,
          blocked_tools: [binary()],
          allow_memory_read: boolean(),
          allow_memory_write: boolean(),
          autonomous?: boolean()
        }

  @doc """
  BeamCore ignores model-authored capability blocks and always uses autonomous mode.
  """
  @spec from_user_message(binary()) :: t()
  def from_user_message(_content), do: default()

  @doc """
  Fully autonomous execution capabilities.

  Hard runtime boundaries still apply in the Eeva runtime.
  """
  @spec yolo(keyword()) :: t()
  def yolo(_opts \\ []) do
    %{
      mode: :yolo,
      allow_task: false,
      allow_network: true,
      allowed_tools: [@tool],
      blocked_tools: [],
      allow_memory_read: true,
      allow_memory_write: true,
      autonomous?: true
    }
  end

  @doc """
  Default autonomous BeamCore capabilities.
  """
  @spec default() :: t()
  def default, do: yolo()

  @doc """
  Chat uses the same autonomous Eeva surface as the rest of BeamCore.
  """
  @spec chat() :: t()
  def chat do
    default()
  end

  @doc """
  Builds the capabilities inherited by an internal sub-agent.
  """
  @spec subagent(binary()) :: t()
  def subagent(_prompt), do: default()

  @doc """
  Returns the model-facing tools permitted by the runtime.

  The result can only be `[]` or `["eeva"]`.
  """
  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(caps) when is_map(caps) do
    runtime_allowed_tool_names(caps)
  end

  @doc """
  Authorizes an external model tool call.

  This only authorizes entry into Eeva. Filesystem, command, network, memory,
  and other effects inside the submitted Elixir program must still be checked
  by Eeva's AST analyzer and runtime guards.
  """
  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(caps, name, args \\ %{})

  def allow_tool_call(caps, @tool, args) when is_map(caps) and is_map(args) do
    if @tool in allowed_tool_names(caps),
      do: :ok,
      else: {:error, "Eeva execution is blocked by runtime safety."}
  end

  def allow_tool_call(_caps, name, _args) do
    {:error, "Unknown tool #{inspect(name)}. BeamCore exposes only eeva."}
  end

  @doc """
  BeamCore never enters a confirmation loop for normal Eeva operations.
  """
  @spec confirmation_required?(t()) :: boolean()
  def confirmation_required?(_caps), do: false

  @spec autonomous?(t()) :: boolean()
  def autonomous?(caps) when is_map(caps) do
    Map.get(caps, :autonomous?, true)
  end

  def autonomous?(_caps), do: true

  @spec network_allowed?(t()) :: boolean()
  def network_allowed?(caps) when is_map(caps) do
    Map.get(caps, :allow_network, true)
  end

  def network_allowed?(_caps), do: true

  @spec write_allowed?(t()) :: boolean()
  def write_allowed?(_caps), do: true

  defp runtime_allowed_tool_names(caps) do
    allowed_tools = Map.get(caps, :allowed_tools)
    blocked_tools = Map.get(caps, :blocked_tools, [])

    cond do
      @tool in blocked_tools ->
        []

      is_list(allowed_tools) and @tool not in allowed_tools ->
        []

      true ->
        [@tool]
    end
  end
end
