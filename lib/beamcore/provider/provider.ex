defmodule Beamcore.Provider do
  @moduledoc """
  Behaviour for chat provider adapters.

  The current chat path still uses the existing OpenAI-compatible client
  boundary, but new provider-aware code should depend on this contract instead
  of branching on provider names in chat, TUI, session, or tool code.
  """

  alias Beamcore.Provider.{Capabilities, Error, Model}

  @type config :: map()
  @type request :: map()
  @type response :: map()
  @type receiver :: pid() | (map() -> any())

  @callback id() :: atom()
  @callback list_models(config()) :: {:ok, [Model.t()]} | {:error, Error.t()}
  @callback capabilities(Model.t() | binary(), config()) :: Capabilities.t()
  @callback chat(request(), config()) :: {:ok, response()} | {:error, Error.t()}
  @callback stream(request(), receiver(), config()) :: {:ok, reference()} | {:error, Error.t()}
  @callback validate_config(config()) :: :ok | {:error, Error.t()}
end
