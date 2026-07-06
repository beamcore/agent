defmodule Beamcore.TUI.MultiScreenState do
  @moduledoc """
  Container for the shell's modes.

  Two modes are backed by real state — `:chat` (the agent chat) and
  `:dashboard` (the System overview). The coming-soon `:research` mode has no
  backing state and renders a placeholder body, so the shell can carry a new
  surface before its feature exists.
  """

  defstruct active_mode: :chat,
            chat_state: nil,
            dashboard_state: nil,
            show_help: false,
            splash?: false,
            splash_step: 0,
            splash_started_at: nil,
            resize_redraw_ref: nil,
            tick_ref: nil,
            started_at: nil

  @doc "The state backing the active mode, or nil for a coming-soon mode."
  def get_active(%__MODULE__{active_mode: :chat} = state), do: state.chat_state
  def get_active(%__MODULE__{active_mode: :dashboard} = state), do: state.dashboard_state
  def get_active(%__MODULE__{}), do: nil

  @doc "Writes a new state back to the active mode's slot; a no-op for coming-soon modes."
  def put_active(%__MODULE__{active_mode: :chat} = state, value), do: %{state | chat_state: value}

  def put_active(%__MODULE__{active_mode: :dashboard} = state, value),
    do: %{state | dashboard_state: value}

  def put_active(%__MODULE__{} = state, _value), do: state

  @doc "Maps the active mode's state through `fun`; a no-op when there is none."
  def update_active(%__MODULE__{} = state, fun) when is_function(fun, 1) do
    case get_active(state) do
      nil -> state
      active -> put_active(state, fun.(active))
    end
  end
end
