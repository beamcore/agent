defmodule Beamcore.TUI.MultiScreenState do
  @moduledoc """
  Manages state for the three screens (F1: Dev, F2: Chat, F3: Providers).
  """

  defstruct active_screen: :f1,
            f1_state: nil,
            f2_state: nil,
            f3_state: nil,
            resize_redraw_ref: nil,
            tick_ref: nil,
            started_at: nil

  def get_active(%__MODULE__{active_screen: :f1} = state), do: state.f1_state
  def get_active(%__MODULE__{active_screen: :f2} = state), do: state.f2_state
  def get_active(%__MODULE__{active_screen: :f3} = state), do: state.f3_state

  def put_active(%__MODULE__{active_screen: :f1} = state, s), do: %{state | f1_state: s}
  def put_active(%__MODULE__{active_screen: :f2} = state, s), do: %{state | f2_state: s}
  def put_active(%__MODULE__{active_screen: :f3} = state, s), do: %{state | f3_state: s}

  def update_active(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    put_active(state, fun.(get_active(state)))
  end
end
