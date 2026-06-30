defmodule Beamcore.TUI.ShellTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MultiScreenState, Shell, State}
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.{Paragraph, Popup, Tabs, Textarea}

  defp frame, do: %Frame{width: 80, height: 24}

  defp multi(active_mode) do
    %MultiScreenState{
      active_mode: active_mode,
      chat_state: State.new(nil, ExRatatui.textarea_new()),
      dashboard_state: TuiSystem.new(:agent)
    }
  end

  test "renders the mode bar on the top row for every mode" do
    [{top_widget, top_rect} | _] = Shell.render(multi(:chat), frame())

    assert %Tabs{selected: 0} = top_widget
    assert top_rect.y == 0
    assert top_rect.height == 1
  end

  test "the mode bar selects the active mode" do
    assert [{%Tabs{selected: 1}, _} | _] = Shell.render(multi(:dashboard), frame())
    assert [{%Tabs{selected: 2}, _} | _] = Shell.render(multi(:research), frame())
  end

  test "renders the chat body, with its composer, below the bar" do
    [_top | body] = Shell.render(multi(:chat), frame())

    assert Enum.any?(body, fn {w, _} -> match?(%Textarea{}, w) end)
    assert Enum.all?(body, fn {_w, rect} -> rect.y >= 1 end)
  end

  test "overlays the help popup when shell help is open" do
    multi = %{multi(:dashboard) | show_help: true}
    widgets = Shell.render(multi, frame())

    assert Enum.any?(widgets, fn {w, _} -> match?(%Popup{block: %{title: "Help"}}, w) end)
  end

  test "renders a coming-soon placeholder body for unbuilt modes" do
    widgets = Shell.render(multi(:research), frame())

    texts =
      for {%Paragraph{text: t}, _} <- widgets, is_binary(t), do: t

    assert Enum.any?(texts, &(&1 =~ "Research"))
    assert Enum.any?(texts, &(&1 =~ "Coming soon"))
  end
end
