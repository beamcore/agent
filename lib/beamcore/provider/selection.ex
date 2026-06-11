defmodule Beamcore.Provider.Selection do
  @moduledoc """
  Immutable provider/model role selection for a session or sub-run.
  """

  defstruct primary: nil,
            fallback: nil

  @type model_selection :: %{
          provider: binary(),
          model: binary(),
          enabled: boolean()
        }

  @type t :: %__MODULE__{
          primary: model_selection(),
          fallback: model_selection() | nil
        }

  def default do
    primary_provider = Beamcore.Config.active_provider()
    primary_model = Beamcore.Agent.Chat.API.default_model()

    %__MODULE__{
      primary: %{provider: primary_provider, model: primary_model, enabled: true},
      fallback: nil
    }
  end

  def primary(%__MODULE__{primary: primary}), do: primary
  def fallback(%__MODULE__{fallback: fallback}), do: fallback

  def put_primary(%__MODULE__{} = selection, provider, model) do
    %{selection | primary: %{provider: provider, model: model, enabled: true}}
  end
end
