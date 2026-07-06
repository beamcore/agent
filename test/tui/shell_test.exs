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

  defp tab_widget(widgets) do
    Enum.find(widgets, fn {w, _rect} -> match?(%Tabs{}, w) end)
  end

  test "renders the mode bar on the second-to-last row for every mode" do
    %Frame{height: h} = frame()
    {tabs, rect} = Shell.render(multi(:chat), frame()) |> tab_widget()

    assert %Tabs{selected: 0} = tabs
    assert rect.y == h - 2
    assert rect.height == 1
  end

  test "the mode bar selects the active mode" do
    assert {%Tabs{selected: 1}, _} = Shell.render(multi(:dashboard), frame()) |> tab_widget()
    assert {%Tabs{selected: 2}, _} = Shell.render(multi(:research), frame()) |> tab_widget()
  end

  test "renders the chat body, with its composer, above the footer" do
    %Frame{height: h} = frame()
    widgets = Shell.render(multi(:chat), frame())

    assert Enum.any?(widgets, fn {w, _} -> match?(%Textarea{}, w) end)
    # The composer sits within the body, above the two-row footer.
    textarea = Enum.find(widgets, fn {w, _} -> match?(%Textarea{}, w) end)
    {_w, rect} = textarea
    assert rect.y < h - 2
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

  # Building the widget tree is not enough: an unsupported constraint or widget
  # only blows up inside ExRatatui.draw/2, which the runtime calls *after*
  # render/2 returns. Draw every mode (and its help overlay) to a headless test
  # terminal so a bad widget surfaces here instead of freezing a live TUI.
  @modes [:chat, :dashboard, :research]

  for mode <- @modes do
    test "draws the #{mode} mode without crashing" do
      m = %{multi(unquote(mode)) | show_help: false}
      assert :ok = draw(Shell.render(m, frame()))
    end

    test "draws the #{mode} mode with the help overlay without crashing" do
      m = %{multi(unquote(mode)) | show_help: true}
      assert :ok = draw(Shell.render(m, frame()))
    end
  end

  defp draw(widgets) do
    %Frame{width: w, height: h} = frame()
    terminal = ExRatatui.init_test_terminal(w, h)
    ExRatatui.draw(terminal, widgets)
  end
end
