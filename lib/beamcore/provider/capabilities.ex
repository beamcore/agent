defmodule Beamcore.Provider.Capabilities do
  @moduledoc """
  Provider-neutral model capabilities used for routing decisions.
  """

  defstruct chat: true,
            streaming: false,
            tool_calls: false,
            parallel_tool_calls: false,
            structured_output: false,
            vision: false,
            local: false,
            context_window: nil,
            latency_class: :unknown,
            token_accounting: false,
            retry_after: false,
            embeddings: false

  @type latency_class :: :low | :medium | :high | :unknown

  @type t :: %__MODULE__{
          chat: boolean(),
          streaming: boolean(),
          tool_calls: boolean(),
          parallel_tool_calls: boolean(),
          structured_output: boolean(),
          vision: boolean(),
          local: boolean(),
          context_window: pos_integer() | nil,
          latency_class: latency_class(),
          token_accounting: boolean(),
          retry_after: boolean(),
          embeddings: boolean()
        }
end
