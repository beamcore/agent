defmodule Beamcore.TUI.Components.Splash do
  @moduledoc """
  The launch splash: the BEAMCORE wordmark in big-text with a beam of light
  sweeping across it, a subtitle, and the mascot waking up.

  The sweep is a brightness wave rather than a hue gradient, so it reads the
  same across every theme (which mostly use named colors) and degrades cleanly:
  non-unicode terminals get a plain ASCII banner, and terminals too small for
  the wordmark get the same banner.
  """

  alias Beamcore.TUI.Components.Mascot
  alias Beamcore.TUI.Theme
  alias ExRatatui.BigText
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph

  @word "BEAMCORE"
  @letters String.graphemes(@word)
  @cell_width 8
  @letter_height 4
  @subtitle "terminal coding agent · distributed by default"
  @ascii_banner "B E A M C O R E"

  @doc "Number of sweep positions: one per letter, plus a short fully-lit settle."
  @spec steps() :: pos_integer()
  def steps, do: length(@letters) + 2

  @doc "The splash scene for a given sweep position (0-based beam head)."
  @spec widgets(map(), integer(), boolean()) :: [{struct(), Rect.t()}]
  def widgets(frame, sweep, unicode?) do
    width = max(frame.width, 1)
    height = max(frame.height, 1)
    band = @cell_width * length(@letters)

    if unicode? and width >= band + 4 and height >= @letter_height + 4 do
      wordmark(width, height, band, sweep)
    else
      [banner(width, height)]
    end
  end

  defp wordmark(width, height, band, sweep) do
    block_height = @letter_height + 4
    top = max(div(height - block_height, 2), 0)
    x0 = div(width - band, 2)

    letters =
      @letters
      |> Enum.with_index()
      |> Enum.map(fn {char, i} ->
        rect = %Rect{x: x0 + i * @cell_width, y: top, width: @cell_width, height: @letter_height}

        widget =
          BigText.new(char,
            pixel_size: :half_height,
            alignment: :center,
            style: letter_style(i, sweep)
          )

        {widget, rect}
      end)

    subtitle = %Rect{x: 0, y: top + @letter_height + 1, width: width, height: 1}
    mascot = %Rect{x: 0, y: top + @letter_height + 3, width: width, height: 1}

    letters ++
      [
        {%Paragraph{text: @subtitle, style: Theme.style(:muted), alignment: :center}, subtitle},
        {%Paragraph{
           text: "#{Mascot.frame(:idle, sweep, true)}  waking up…",
           style: Theme.style(:status),
           alignment: :center
         }, mascot}
      ]
  end

  defp letter_style(index, sweep) do
    base = Theme.style(:accent)

    cond do
      index == sweep -> %{base | modifiers: [:bold | base.modifiers]}
      index < sweep -> base
      true -> %{base | modifiers: [:dim | base.modifiers]}
    end
  end

  defp banner(width, height) do
    rect = %Rect{x: 0, y: div(height, 2), width: width, height: 1}
    {%Paragraph{text: @ascii_banner, style: Theme.style(:accent), alignment: :center}, rect}
  end
end
