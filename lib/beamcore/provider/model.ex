defmodule Beamcore.Provider.Model do
  @moduledoc """
  Provider-neutral model descriptor.
  """

  alias Beamcore.Provider.Capabilities

  defstruct [:id, :name, :capabilities]

  @type t :: %__MODULE__{
          id: binary(),
          name: binary() | nil,
          capabilities: Capabilities.t()
        }
end
