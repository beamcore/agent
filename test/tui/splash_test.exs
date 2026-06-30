defmodule Beamcore.TUI.Components.SplashTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Components.Splash
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.{BigText, Paragraph}

  defp big_texts(widgets), do: for({%BigText{} = w, _} <- widgets, do: w)

  defp frame(w \\ 100, h \\ 30), do: %Frame{width: w, height: h}

  test "renders the wordmark as one big-text letter per character" do
    letters = big_texts(Splash.widgets(frame(), 0, true))
    assert length(letters) == String.length("BEAMCORE")
  end

  test "the beam head is bold, letters ahead of it are dim, lit letters are neither" do
    letters = big_texts(Splash.widgets(frame(), 3, true))

    assert :bold in Enum.at(letters, 3).style.modifiers
    assert :dim in Enum.at(letters, 5).style.modifiers

    behind = Enum.at(letters, 1).style.modifiers
    refute :bold in behind
    refute :dim in behind
  end

  test "includes the subtitle tagline" do
    widgets = Splash.widgets(frame(), 0, true)
    texts = for {%Paragraph{text: t}, _} <- widgets, is_binary(t), do: t
    assert Enum.any?(texts, &(&1 =~ "terminal coding agent"))
  end

  test "falls back to a plain ASCII banner when unicode is unavailable" do
    widgets = Splash.widgets(frame(), 0, false)

    assert big_texts(widgets) == []
    assert [{%Paragraph{text: text}, _}] = widgets
    assert text =~ "B E A M C O R E"
  end

  test "falls back when the terminal is too small for the wordmark" do
    assert big_texts(Splash.widgets(frame(40, 8), 0, true)) == []
  end

  test "steps/0 covers the full sweep plus a short settle" do
    assert Splash.steps() == String.length("BEAMCORE") + 2
  end
end
