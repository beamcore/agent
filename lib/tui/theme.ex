defmodule Beamcore.TUI.Theme do
  @moduledoc """
  Theme system for the TUI.

  Themes use terminal default colors where possible. Branded themes
  use their signature RGB palette. Switch at runtime with `set_theme/1`
  or via the `/theme` command.

  30 themes available:
    :default      — terminal defaults
    :arctic       — ice blue/white
    :ayu          — clean modern
    :catppuccin   — pastel warm (mocha)
    :cherry       — red/pink on dark
    :cyberpunk    — neon pink/cyan
    :dracula      — purple/cyan
    :everforest   — green nature
    :forest       — deep green
    :github       — light clean
    :gotham       — dark blue
    :gruvbox      — retro warm
    :kanagawa     — japanese ink
    :lavender     — purple/violet
    :matrix       — green on black
    :melange      — muted warm
    :molokai      — classic dark
    :monokai      — classic vivid
    :nightfox     — warm dark
    :nord         — arctic blue
    :ocean        — deep blue/teal
    :one_dark     — atom dark
    :palenight    — purple dark
    :retro_terminal — amber on dark
    :rose_pine    — soft pink
    :solarized    — balanced
    :sunset       — warm orange/pink
    :tokyo_night  — cool purple
    :volcanic     — red/orange on dark
    :zenburn      — low contrast
  """

  alias ExRatatui.Style
  alias ExRatatui.Text.Span

  @themes %{
    default: Beamcore.TUI.Themes.Default,
    arctic: Beamcore.TUI.Themes.Arctic,
    ayu: Beamcore.TUI.Themes.Ayu,
    catppuccin: Beamcore.TUI.Themes.Catppuccin,
    cherry: Beamcore.TUI.Themes.Cherry,
    cyberpunk: Beamcore.TUI.Themes.Cyberpunk,
    dracula: Beamcore.TUI.Themes.Dracula,
    everforest: Beamcore.TUI.Themes.Everforest,
    forest: Beamcore.TUI.Themes.Forest,
    github: Beamcore.TUI.Themes.GitHub,
    gotham: Beamcore.TUI.Themes.Gotham,
    gruvbox: Beamcore.TUI.Themes.Gruvbox,
    kanagawa: Beamcore.TUI.Themes.Kanagawa,
    lavender: Beamcore.TUI.Themes.Lavender,
    matrix: Beamcore.TUI.Themes.Matrix,
    melange: Beamcore.TUI.Themes.Melange,
    molokai: Beamcore.TUI.Themes.Molokai,
    monokai: Beamcore.TUI.Themes.Monokai,
    nightfox: Beamcore.TUI.Themes.Nightfox,
    nord: Beamcore.TUI.Themes.Nord,
    ocean: Beamcore.TUI.Themes.Ocean,
    one_dark: Beamcore.TUI.Themes.OneDark,
    palenight: Beamcore.TUI.Themes.Palenight,
    retro_terminal: Beamcore.TUI.Themes.RetroTerminal,
    rose_pine: Beamcore.TUI.Themes.RosePine,
    solarized: Beamcore.TUI.Themes.Solarized,
    sunset: Beamcore.TUI.Themes.Sunset,
    tokyo_night: Beamcore.TUI.Themes.TokyoNight,
    volcanic: Beamcore.TUI.Themes.Volcanic,
    zenburn: Beamcore.TUI.Themes.Zenburn
  }

  @default_theme :default

  @spec list_themes() :: [atom()]
  def list_themes, do: Map.keys(@themes)

  @spec set_theme(atom()) :: :ok | {:error, :unknown_theme}
  def set_theme(name) when is_map_key(@themes, name) do
    Application.put_env(:beamcore, :tui_theme, name)
    Beamcore.Config.put(:tui_theme, Atom.to_string(name))
    :ok
  end

  def set_theme(_name), do: {:error, :unknown_theme}

  @spec current_theme() :: atom()
  def current_theme do
    case Application.get_env(:beamcore, :tui_theme) do
      nil ->
        name = load_persisted_theme()
        Application.put_env(:beamcore, :tui_theme, name)
        name

      name ->
        name
    end
  end

  @spec style(atom()) :: Style.t()
  def style(name) do
    styles = current_theme_module().styles()
    Map.get(styles, name, %Style{})
  end

  @spec border(atom()) :: Style.t()
  def border(:error), do: style(:error)
  def border(_status), do: style(:border)

  @doc """
  A filled "chip" style derived from the current theme's accent color.

  The accent foreground becomes the chip background with black, bold text —
  the same technique the sibling ex_ratatui TUIs use for active tabs and key
  hints, but derived per-theme so no theme file needs its own chip token.
  """
  @spec chip_style() :: Style.t()
  def chip_style do
    %Style{bg: style(:accent).fg, fg: :black, modifiers: [:bold]}
  end

  @doc "A key hint rendered as a padded `chip_style/0` span, e.g. `\" ^C \"`."
  @spec key_pill(String.t()) :: Span.t()
  def key_pill(label) when is_binary(label) do
    %Span{content: " #{label} ", style: chip_style()}
  end

  defp current_theme_module do
    Map.get(@themes, current_theme(), Map.get(@themes, @default_theme))
  end

  defp load_persisted_theme do
    case Beamcore.Config.get(:tui_theme) do
      name when is_binary(name) ->
        atom = String.to_existing_atom(String.trim(name))
        if Map.has_key?(@themes, atom), do: atom, else: @default_theme

      _ ->
        @default_theme
    end
  rescue
    _ -> @default_theme
  end
end
