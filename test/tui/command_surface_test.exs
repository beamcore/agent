defmodule Beamcore.TUI.CommandSurfaceTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.EmptyState
  alias Beamcore.TUI.Events.Commands
  alias Beamcore.TUI.State

  defp suggestion_names(input) do
    textarea = ExRatatui.textarea_new()
    ExRatatui.textarea_set_value(textarea, input)

    State.new(nil, textarea)
    |> Commands.refresh_commands()
    |> Map.fetch!(:command_matches)
    |> Enum.map(& &1.name)
  end

  describe "the slash-command suggestion list" do
    test "drops the redundant exit aliases and the help command" do
      names = suggestion_names("/")

      refute "exit" in names
      refute "q" in names
      refute "help" in names
    end

    test "keeps the functional commands" do
      names = suggestion_names("/")

      for keep <- ["quit", "theme", "new", "stop", "clear", "attach", "detach", "api list"] do
        assert keep in names, "expected /#{keep} to remain a suggestion"
      end
    end
  end

  describe "the empty-state hint" do
    test "points discovery at the ? help popup, not /help or /commands" do
      text = EmptyState.text(%{memory_total: 0})

      assert text =~ "? help"
      refute text =~ "/help"
      refute text =~ "/commands"
    end
  end
end
