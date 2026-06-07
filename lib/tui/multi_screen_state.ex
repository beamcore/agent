defmodule Beamcore.TUI.MultiScreenState do
  @moduledoc """
  Manages state for multiple screens (F1: Dev, F2: Chat, F3: Research).
  """

  defstruct active_screen: :f1,
            f1_state: nil,
            f2_state: nil,
            f3_state: nil

  def get_active(%__MODULE__{active_screen: :f1} = state), do: state.f1_state
  def get_active(%__MODULE__{active_screen: :f2} = state), do: state.f2_state
  def get_active(%__MODULE__{active_screen: :f3} = state), do: state.f3_state

  def put_active(%__MODULE__{active_screen: :f1} = state, active_state),
    do: %{state | f1_state: active_state}

  def put_active(%__MODULE__{active_screen: :f2} = state, active_state),
    do: %{state | f2_state: active_state}

  def put_active(%__MODULE__{active_screen: :f3} = state, active_state),
    do: %{state | f3_state: active_state}

  def update_active(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    active_state = get_active(state)
    put_active(state, fun.(active_state))
  end
end
