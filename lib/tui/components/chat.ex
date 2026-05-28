defmodule Beamcore.TUI.Components.Chat do
  @moduledoc false

  alias Beamcore.TUI.Components.{Confirmation, EmptyState}
  alias Beamcore.TUI.{State, Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Throbber, WidgetList}

   def widget(state, %Rect{} = area) do
     wrap_width = content_width(area)

     items =
       state
       |> message_items(wrap_width)
       |> append_confirmation(state, wrap_width)
       |> append_spinner(state)

     %WidgetList{
       items: items,
       scroll_offset: scroll_offset(items, area, state.scroll_offset),
       block: %Block{
         borders: [],
         padding: {0, 0, 0, 0}
       }
     }
   end

   def render_message_lines(label, content, width) do
     [label | Wrap.lines(content, width)]
   end

   defp message_items(%{messages: []} = state, wrap_width) do
     text = state |> EmptyState.text() |> Wrap.text(wrap_width)
     [{EmptyState.widget(text), max(5, line_count(text))}]
   end

  defp message_items(%{messages: messages}, wrap_width) do
    Enum.flat_map(messages, fn
      %{role: :user, content: content} ->
        bubble("You", content, Theme.style(:user), wrap_width, :plain)

      %{role: :assistant, content: content} ->
        bubble("Agent", content, Theme.style(:accent), wrap_width, :markdown)

      %{role: :tool, content: content} ->
        bubble("Tool", content, Theme.style(:queued), wrap_width, :plain)

      %{role: :error, content: content} ->
        bubble("Error", content, Theme.style(:error), wrap_width, :plain)

      %{content: content} ->
        bubble("System", content, Theme.style(:muted), wrap_width, :plain)
    end)
  end

   defp bubble(label, content, style, wrap_width, kind) do
     body_width = max(wrap_width - 2, 10)

     lines =
       case kind do
         :markdown -> Wrap.markdown_lines(content, body_width)
         :plain -> Wrap.lines(content, body_width)
       end

     prefix = label_prefix(label)
     card = card_text(prefix, lines, wrap_width)

     [
       {%Paragraph{text: card, style: style, wrap: false}, line_count(card)},
       {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
     ]
   end

   defp label_prefix("You"), do: ">"
   defp label_prefix("Agent"), do: "*"
   defp label_prefix("Tool"), do: "»"
   defp label_prefix("Error"), do: "!"
   defp label_prefix("System"), do: "·"
   defp label_prefix(label), do: String.slice(label, 0, 1)

   defp card_text(prefix, lines, wrap_width) do
     body =
       lines
       |> Enum.flat_map(&split_preserving_width(&1, max(wrap_width - 2, 10)))
       |> Enum.map(&"  #{&1}")

     (["#{prefix} " <> String.trim(Enum.join(body, "\n"))])
     |> Enum.join("\n")
   end

   defp split_preserving_width(line, width), do: Wrap.lines(line, width)

  defp append_confirmation(items, state, wrap_width) do
    case State.pending_action(state.session) do
      nil -> items
      action -> items ++ Confirmation.items(action, wrap_width)
    end
  end

   defp append_spinner(items, %{status: status} = state)
       when status in [:thinking, :tool_running] do
     label = if status == :tool_running, do: "… running tools", else: "… thinking"
     set = if state.unicode?, do: :braille, else: :ascii

     items ++
       [
         {%Throbber{
             label: label,
             step: state.spinner_step,
             throbber_set: set,
             style: Theme.style(:subtle),
             throbber_style: Theme.style(:running)
           }, 1}
       ]
   end

   defp append_spinner(items, _state), do: items

  defp line_count(text), do: text |> to_string() |> String.split("\n") |> length()

  defp content_width(%Rect{width: width}), do: max(width - 4, 12)

  defp scroll_offset(items, %Rect{height: height}, distance_from_bottom) do
    content_height =
      items
      |> Enum.map(fn {_widget, item_height} -> item_height end)
      |> Enum.sum()

    viewport_height = max(height - 2, 1)
    max_scroll = max(content_height - viewport_height, 0)
    max(max_scroll - distance_from_bottom, 0)
  end
end
