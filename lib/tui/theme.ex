defmodule Beamcore.TUI.Theme do
  @moduledoc """
  Theme system for the TUI.

  Themes use terminal default colors where possible. Branded themes
  use their signature RGB palette. Switch at runtime with `set_theme/1`
  or via the `/theme` command.

  20 themes available:
    :default      — terminal defaults
    :ayu          — clean modern
    :catppuccin   — pastel warm (mocha)
    :dracula      — purple/cyan
    :everforest   — green nature
    :github       — light clean
    :gotham       — dark blue
    :gruvbox      — retro warm
    :kanagawa     — japanese ink
    :melange      — muted warm
    :molokai      — classic dark
    :monokai      — classic vivid
    :nightfox     — warm dark
    :nord         — arctic blue
    :one_dark     — atom dark
    :palenight    — purple dark
    :rose_pine    — soft pink
    :solarized    — balanced
    :tokyo_night  — cool purple
    :zenburn      — low contrast
  """

  alias ExRatatui.Style

  @themes %{
    default: Beamcore.TUI.Themes.Default,
    ayu: Beamcore.TUI.Themes.Ayu,
    catppuccin: Beamcore.TUI.Themes.Catppuccin,
    dracula: Beamcore.TUI.Themes.Dracula,
    everforest: Beamcore.TUI.Themes.Everforest,
    github: Beamcore.TUI.Themes.GitHub,
    gotham: Beamcore.TUI.Themes.Gotham,
    gruvbox: Beamcore.TUI.Themes.Gruvbox,
    kanagawa: Beamcore.TUI.Themes.Kanagawa,
    melange: Beamcore.TUI.Themes.Melange,
    molokai: Beamcore.TUI.Themes.Molokai,
    monokai: Beamcore.TUI.Themes.Monokai,
    nightfox: Beamcore.TUI.Themes.Nightfox,
    nord: Beamcore.TUI.Themes.Nord,
    one_dark: Beamcore.TUI.Themes.OneDark,
    palenight: Beamcore.TUI.Themes.Palenight,
    rose_pine: Beamcore.TUI.Themes.RosePine,
    solarized: Beamcore.TUI.Themes.Solarized,
    tokyo_night: Beamcore.TUI.Themes.TokyoNight,
    zenburn: Beamcore.TUI.Themes.Zenburn
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
