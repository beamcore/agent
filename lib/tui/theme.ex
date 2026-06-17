defmodule Beamcore.TUI.Theme do
  @moduledoc """
  Theme system for the TUI.

  Themes use terminal default colors where possible. Branded themes
  use their signature RGB palette. Switch at runtime with `set_theme/1`.

  Available themes:
    :default      — terminal defaults, muted gray accents
    :dracula      — purple/cyan on dark
    :nord         — arctic blue tones
    :solarized    — warm balanced palette
    :tokyo_night  — cool blue/purple
    :catppuccin   — pastel warm tones
  """

  alias ExRatatui.Style

  @themes %{
    default: Beamcore.TUI.Themes.Default,
    dracula: Beamcore.TUI.Themes.Dracula,
    nord: Beamcore.TUI.Themes.Nord,
    solarized: Beamcore.TUI.Themes.Solarized,
    tokyo_night: Beamcore.TUI.Themes.TokyoNight,
    catppuccin: Beamcore.TUI.Themes.Catppuccin
  }

  @default_theme :default

  @spec list_themes() :: [atom()]
  def list_themes, do: Map.keys(@themes)

  @spec set_theme(atom()) :: :ok | {:error, :unknown_theme}
  def set_theme(name) when is_map_key(@themes, name) do
    Application.put_env(:beamcore, :tui_theme, name)
    :ok
  end

  def set_theme(_name), do: {:error, :unknown_theme}

  @spec current_theme() :: atom()
  def current_theme do
    Application.get_env(:beamcore, :tui_theme, @default_theme)
  end

  @spec style(atom()) :: Style.t()
  def style(name) do
    styles = current_theme_module().styles()
    Map.get(styles, name, %Style{})
  end

  @spec border(atom()) :: Style.t()
  def border(:error), do: style(:error)
  def border(_status), do: style(:border)

  defp current_theme_module do
    Map.get(@themes, current_theme(), Map.get(@themes, @default_theme))
  end
end
