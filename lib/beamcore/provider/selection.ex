defmodule Beamcore.Provider.Selection do
  @moduledoc """
  Immutable provider/model role selection for a session or sub-run.
  """

  defstruct primary: nil,
            helper: nil,
            fallback: nil

  @type model_selection :: %{
          provider: binary(),
          model: binary(),
          enabled: boolean()
        }

  @type t :: %__MODULE__{
          primary: model_selection(),
          helper: model_selection() | nil,
          fallback: model_selection() | nil
        }

  def default do
    primary_provider = Beamcore.Config.active_provider()
    primary_model = Beamcore.Agent.Chat.API.default_model()

    %__MODULE__{
      primary: %{provider: primary_provider, model: primary_model, enabled: true},
      helper: configured_helper(),
      fallback: nil
    }
  end

  def primary(%__MODULE__{primary: primary}), do: primary
  def helper(%__MODULE__{helper: helper}), do: helper
  def fallback(%__MODULE__{fallback: fallback}), do: fallback

  def put_primary(%__MODULE__{} = selection, provider, model) do
    %{selection | primary: %{provider: provider, model: model, enabled: true}}
  end

  def put_helper(%__MODULE__{} = selection, provider, model, enabled \\ true) do
    %{selection | helper: %{provider: provider, model: model, enabled: enabled}}
  end

  def disable_helper(%__MODULE__{} = selection) do
    case selection.helper do
      nil -> selection
      helper -> %{selection | helper: %{helper | enabled: false}}
    end
  end

  defp configured_helper do
    Beamcore.Config.helper_selection()
  end
end
