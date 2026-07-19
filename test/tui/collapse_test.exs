defmodule Beamcore.TUI.CollapseTest do
  use ExUnit.Case, async: true

  alias Beamcore.TUI.Events.Keyboard
  alias Beamcore.TUI.Components.Chat.Bubbles.CodeBlock.Eeva
  alias Beamcore.TUI.Components.Chat.MessageWindow
  alias Beamcore.TUI.State
  alias ExRatatui.Text.Line
  alias ExRatatui.Widgets.Paragraph

  @code_content String.duplicate("IO.puts(\"hello\")\n", 20)

  defp state_with_messages(messages) do
    %State{messages: messages, collapsed_blocks: %{}, render_dirty?: false}
  end

  defp member?(collapsed_blocks, idx) do
    MapSet.member?(Map.get(collapsed_blocks, idx, MapSet.new()), 0)
  end

  describe "toggle_code_block/3" do
    test "toggles block from collapsed to expanded" do
      state = state_with_messages([%{role: :eeva_preview, content: @code_content}])
      toggled = State.toggle_code_block(state, 0, 0)
      assert member?(toggled.collapsed_blocks, 0)
    end

    test "toggles block from expanded to collapsed" do
      state = state_with_messages([%{role: :eeva_preview, content: @code_content}])
      toggled = State.toggle_code_block(state, 0, 0)
      toggled_back = State.toggle_code_block(toggled, 0, 0)
      refute member?(toggled_back.collapsed_blocks, 0)
    end
  end

  describe "collapsed eeva rendering" do
    test "hides the complete source block" do
      source = "IO.puts(\"secret\")\nFile.read!(\"private.txt\")"

      assert [
               {%Paragraph{text: [%Line{spans: spans}]}, 1},
               {%Paragraph{}, 1}
             ] = Eeva.render(source, 80, MapSet.new([0]))

      header = spans |> Enum.map_join(& &1.content)
      assert header == "  [+] 2 lines hidden (Ctrl+E)"
      refute header =~ "secret"
      refute inspect(spans) =~ "private.txt"
    end

    test "height estimate matches the collapsed renderer" do
      message = %{role: :eeva_preview, content: @code_content}
      collapsed = %{0 => MapSet.new([0])}

      assert MessageWindow.estimated_message_height(message, 80, collapsed, 0) == 2
    end
  end

  describe "toggle_all_collapsible/1" do
    test "collapses all eeva_preview when any expanded" do
      state =
        state_with_messages([
          %{role: :eeva_preview, content: @code_content},
          %{role: :eeva_preview, content: @code_content}
        ])

      toggled = State.toggle_all_collapsible(state)
      assert member?(toggled.collapsed_blocks, 0)
      assert member?(toggled.collapsed_blocks, 1)
    end

    test "expands all when all collapsed" do
      state =
        state_with_messages([
          %{role: :eeva_preview, content: @code_content},
          %{role: :eeva_preview, content: @code_content}
        ])

      collapsed = State.toggle_all_collapsible(state)
      expanded = State.toggle_all_collapsible(collapsed)
      refute member?(expanded.collapsed_blocks, 0)
      refute member?(expanded.collapsed_blocks, 1)
    end

    test "ignores assistant and user messages" do
      state =
        state_with_messages([
          %{role: :user, content: "question"},
          %{role: :assistant, content: @code_content},
          %{role: :eeva_preview, content: @code_content}
        ])

      toggled = State.toggle_all_collapsible(state)
      refute Map.has_key?(toggled.collapsed_blocks, 0)
      refute Map.has_key?(toggled.collapsed_blocks, 1)
      assert member?(toggled.collapsed_blocks, 2)
    end
  end

  describe "Ctrl+E keyboard handler" do
    test "Ctrl+E collapses all eeva_preview messages" do
      state =
        state_with_messages([
          %{role: :eeva_preview, content: @code_content},
          %{role: :eeva_preview, content: @code_content}
        ])

      {:noreply, new_state} = Keyboard.handle_key("e", ["ctrl"], state)
      assert member?(new_state.collapsed_blocks, 0)
      assert member?(new_state.collapsed_blocks, 1)
    end

    test "Ctrl+E does nothing when no eeva_preview messages" do
      state =
        state_with_messages([
          %{role: :user, content: "question"},
          %{role: :assistant, content: "answer"}
        ])

      {:noreply, new_state} = Keyboard.handle_key("e", ["ctrl"], state)
      assert new_state.collapsed_blocks == %{}
    end

    test "plain 'e' without ctrl does not toggle" do
      state = state_with_messages([%{role: :eeva_preview, content: @code_content}])
      assert state.collapsed_blocks == %{}
    end
  end
end
