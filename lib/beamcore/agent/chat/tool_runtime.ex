defmodule Beamcore.Agent.Chat.ToolRuntime do
  @moduledoc """
  Runtime capabilities for the single Eeva execution surface.

  BeamCore exposes exactly one model-facing tool: `eeva`. The model writes
  ordinary Elixir code and uses that one surface for inspection, edits,
  validation, provider-visible diagnostics, and memory access.
  """

  @tool "eeva"

  @type t :: %{
          allow_network: boolean(),
          allow_memory_read: boolean(),
          allow_memory_write: boolean()
        }

  @doc """
  Default autonomous execution capabilities.

  The default is autonomous. Operator controls that still matter live in the
  execution layer and documented environment/config settings rather than hidden
  tool filtering.
  """
  @spec default(keyword()) :: t()
  def default(_opts \\ []) do
    %{
      allow_network: true,
      allow_memory_read: true,
      allow_memory_write: true
    }
  end

  @doc """
  Chat uses the same autonomous Eeva surface as the rest of BeamCore.
  """
  @spec chat() :: t()
  def chat, do: default()

  @doc """
  Returns the model-facing tools exposed by the runtime.
  """
  @spec allowed_tool_names(t()) :: [binary()]
  def allowed_tool_names(_caps), do: [@tool]

  @doc """
  Authorizes an external model tool call.

  This only authorizes entry into Eeva. Unknown legacy tools are rejected because
  they do not exist in the current model-facing API.
  """
  @spec allow_tool_call(t(), binary(), map()) :: :ok | {:error, binary()}
  def allow_tool_call(caps, name, args \\ %{})

  def allow_tool_call(caps, @tool, args) when is_map(caps) and is_map(args), do: :ok

  def allow_tool_call(_caps, name, _args) do
    {:error, "Unknown tool #{inspect(name)}. BeamCore exposes only eeva."}
  end

  @spec network_allowed?(t()) :: boolean()
  def network_allowed?(caps) when is_map(caps) do
    Map.get(caps, :allow_network, true)
  end

  def network_allowed?(_caps), do: true

  @spec write_allowed?(t()) :: boolean()
  def write_allowed?(_caps), do: true
end
