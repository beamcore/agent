defmodule Beamcore.TUI.Components.Chat do
  @moduledoc false

  alias Beamcore.TUI.Components.EmptyState
  alias Beamcore.TUI.{State, Theme, Wrap}
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Throbber, WidgetList}

  @whitespace_rx ~r/^\s+/
  @comment_rx ~r/^#[^\n]*/
  @string_rx ~r/^"([^"\\]|\\.)*"/
  @atom_rx ~r/^:[a-zA-Z_][a-zA-Z0-9_?!]*/
  @atom_key_rx ~r/^[a-zA-Z_][a-zA-Z0-9_?!]*:/
  @keyword_rx ~r/^(defmodule|defp|def|do|end|case|cond|if|else|fn|with|alias|import|require|use|try|catch|rescue|after|receive|raise|quote|unquote|nil|true|false)\b/
  @module_rx ~r/^[A-Z][a-zA-Z0-9_]*/
  @number_rx ~r/^\b\d+(?:\.\d+)?\b/
  @identifier_rx ~r/^[a-z_][a-zA-Z0-9_?!]*/
  @operator_rx ~r/^(->|\|>|=>|==|!=|=~|<=|>=|<>|&&|\|\||\+\+|--|=|\+|-|\*|\/|%|<|>)/

  def widget(state, %Rect{} = area) do
    wrap_width = content_width(area)

    items =
      state
      |> message_items(wrap_width)
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

      %{role: :thinking, content: content} ->
        bubble("Thinking", content, Theme.style(:subtle), wrap_width, :plain)

      %{role: :tool, content: content} ->
        tool_bubble("Modify File", content, wrap_width)

      %{role: :error, content: content} ->
        bubble("Error", content, Theme.style(:error), wrap_width, :plain)

      %{role: :local, content: content} ->
        bubble("Helper", content, Theme.style(:status_hot), wrap_width, :plain)

      %{role: :eeva_preview, content: content} ->
        eeva_preview_bubble(content, wrap_width)

      %{role: :memory, content: content} ->
        bubble("Memory", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{role: :checkpoint, content: content} ->
        bubble("Checkpoint", content, Theme.style(:checkpoint), wrap_width, :plain)

      %{content: content} ->
        bubble("System", content, Theme.style(:muted), wrap_width, :plain)
    end)
  end

  defp tool_bubble(label, content, wrap_width) do
    body_width = max(wrap_width - 2, 10)
    col_width = div(body_width - 5, 2) |> max(10)

    {header, diff_part} =
      case String.split(to_string(content), "\n\n", parts: 2) do
        [hdr, diff] -> {hdr, diff}
        [hdr] -> {hdr, ""}
      end

    header_lines =
      header
      |> String.split(~r/\r?\n/)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        %Line{spans: [%Span{content: "  " <> line, style: Theme.style(:muted)}]}
      end)

    diff_lines = String.split(diff_part, ~r/\r?\n/)

    {parsed_diff_lines, pending_del, pending_add} =
      Enum.reduce(diff_lines, {[], [], []}, fn line, {acc, dels, adds} ->
        cond do
          String.starts_with?(line, "---") or String.starts_with?(line, "+++") ->
            {acc, dels, adds}

          String.starts_with?(line, "@@") ->
            acc = flush_changes(acc, dels, adds, col_width)
            hunk_hdr = parse_hunk_line(line)
            hunk_line = %Line{spans: [%Span{content: hunk_hdr, style: Theme.style(:accent)}]}
            {acc ++ [hunk_line], [], []}

          String.starts_with?(line, "-") ->
            del_text = String.slice(line, 1..-1//1)
            {acc, dels ++ [del_text], adds}

          String.starts_with?(line, "+") ->
            add_text = String.slice(line, 1..-1//1)
            {acc, dels, adds ++ [add_text]}

          true ->
            acc = flush_changes(acc, dels, adds, col_width)
            {acc, [], []}
        end
      end)

    final_diff_lines = flush_changes(parsed_diff_lines, pending_del, pending_add, col_width)

    prefix = label_prefix(label)

    first_line = %Line{
      spans: [
        %Span{content: "#{prefix} #{label}", style: Theme.style(:accent)}
      ]
    }

    all_lines = [first_line] ++ header_lines ++ final_diff_lines

    [
      {%Paragraph{text: all_lines, style: Theme.style(:muted), wrap: false}, length(all_lines)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp flush_changes(lines_acc, [], [], _col_width), do: lines_acc

  defp flush_changes(lines_acc, deletions, additions, col_width) do
    max_len = max(length(deletions), length(additions))

    new_lines =
      if max_len == 0 do
        []
      else
        Enum.map(0..(max_len - 1), fn i ->
          del = Enum.at(deletions, i) || ""
          add = Enum.at(additions, i) || ""

          del_padded = pad_or_truncate(del, col_width)
          add_padded = pad_or_truncate(add, col_width)

          del_style = if del == "", do: Theme.style(:muted), else: Theme.style(:error)
          add_style = if add == "", do: Theme.style(:muted), else: Theme.style(:done)

          %Line{
            spans: [
              %Span{content: "  " <> del_padded, style: del_style},
              %Span{content: " | ", style: Theme.style(:subtle)},
              %Span{content: add_padded, style: add_style}
            ]
          }
        end)
      end

    lines_acc ++ new_lines
  end

  defp parse_hunk_line(line) do
    case Regex.run(~r/@@ -(\d+),?\d* \+(\d+),?\d* @@/, line) do
      [_, orig_line, _new_line] ->
        "  Line #{orig_line}:"

      _ ->
        "  Change:"
    end
  end

  defp pad_or_truncate(text, width) do
    text = to_string(text)
    text_len = String.length(text)

    cond do
      text_len == width ->
        text

      text_len < width ->
        text <> String.duplicate(" ", width - text_len)

      true ->
        String.slice(text, 0, max(width - 3, 0)) <> "..."
    end
  end

  defp bubble(label, content, style, wrap_width, kind) do
    body_width = max(wrap_width - 2, 10)

    lines =
      case kind do
        :markdown -> Wrap.markdown_lines(to_string(content), body_width)
        :plain -> Wrap.lines(to_string(content), body_width)
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
  defp label_prefix("Thinking"), do: "·"
  defp label_prefix("Tool"), do: "»"
  defp label_prefix("Modify File"), do: "»"
  defp label_prefix("Error"), do: "!"
  defp label_prefix("System"), do: "·"
  defp label_prefix("Helper"), do: "·"
  defp label_prefix("Memory"), do: "◆"
  defp label_prefix("Checkpoint"), do: "◇"
  defp label_prefix(label), do: label |> to_string() |> String.slice(0, 1)

  defp card_text(prefix, lines, wrap_width) do
    body =
      lines
      |> Enum.flat_map(&split_preserving_width(&1, max(wrap_width - 2, 10)))
      |> Enum.map(&"  #{&1}")

    trimmed_body =
      body
      |> Enum.join("\n")
      |> String.trim()

    ["#{prefix} " <> trimmed_body]
    |> Enum.join("\n")
  end

  defp split_preserving_width(line, width), do: Wrap.lines(to_string(line), width)

  defp append_spinner(items, %{status: status} = state)
       when status in [:thinking, :tool_running, :local_search] do
    label =
      case status do
        :tool_running -> "… running tools"
        :local_search -> "… context helper (#{State.helper_label(state.session)})"
        _ -> "… thinking"
      end

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

  defp eeva_preview_bubble(code, wrap_width) do
    first_line = %Line{
      spans: [
        %Span{content: "⚡ EEVA", style: Theme.style(:accent)}
      ]
    }

    max_len = max(wrap_width - 4, 10)

    code_lines =
      code
      |> to_string()
      |> String.split(~r/\r?\n/)
      |> Enum.map(fn line ->
        line
        |> tokenize_line()
        |> limit_tokens_length(max_len)
        |> format_highlighted_line()
      end)

    all_lines = [first_line | code_lines]

    [
      {%Paragraph{text: all_lines, style: Theme.style(:muted), wrap: false}, length(all_lines)},
      {%Paragraph{text: "", style: Theme.style(:subtle)}, 1}
    ]
  end

  defp tokenize_line(line) do
    tokenize_line(to_string(line), [])
  end

  defp tokenize_line("", acc), do: Enum.reverse(acc)

  defp tokenize_line(str, acc) do
    cond do
      match = Regex.run(@whitespace_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:whitespace, val} | acc])

      match = Regex.run(@comment_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:comment, val} | acc])

      match = Regex.run(@string_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:string, val} | acc])

      match = Regex.run(@atom_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:atom, val} | acc])

      match = Regex.run(@atom_key_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:atom, val} | acc])

      match = Regex.run(@keyword_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:keyword, val} | acc])

      match = Regex.run(@module_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:module, val} | acc])

      match = Regex.run(@number_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:number, val} | acc])

      match = Regex.run(@identifier_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:identifier, val} | acc])

      match = Regex.run(@operator_rx, str) ->
        val = List.first(match)
        tokenize_line(String.slice(str, String.length(val)..-1//1), [{:operator, val} | acc])

      true ->
        case String.next_grapheme(str) do
          {char, rest} ->
            tokenize_line(rest, [{:text, char} | acc])

          nil ->
            Enum.reverse(acc)
        end
    end
  end

  defp limit_tokens_length(tokens, max_len) do
    limit_tokens_length(tokens, max_len, [])
  end

  defp limit_tokens_length([], _max_len, acc), do: Enum.reverse(acc)

  defp limit_tokens_length([{type, content} | rest], max_len, acc) do
    len = String.length(content)

    cond do
      max_len <= 0 ->
        Enum.reverse(acc)

      len <= max_len ->
        limit_tokens_length(rest, max_len - len, [{type, content} | acc])

      true ->
        truncated_content = String.slice(content, 0, max(max_len - 1, 0)) <> "…"
        Enum.reverse([{type, truncated_content} | acc])
    end
  end

  defp format_highlighted_line(tokens) do
    spans =
      case tokens do
        [] ->
          [%Span{content: "  ", style: Theme.style(:base)}]

        [{type, first_content} | rest] ->
          first_span = %Span{content: "  " <> first_content, style: token_style(type)}

          other_spans =
            Enum.map(rest, fn {type, content} ->
              %Span{content: content, style: token_style(type)}
            end)

          [first_span | other_spans]
      end

    %Line{spans: spans}
  end

  defp token_style(:keyword), do: Theme.style(:accent)
  defp token_style(:comment), do: Theme.style(:subtle)
  defp token_style(:string), do: Theme.style(:done)
  defp token_style(:atom), do: Theme.style(:checkpoint)
  defp token_style(:number), do: Theme.style(:running)
  defp token_style(:module), do: Theme.style(:status_hot)
  defp token_style(:operator), do: Theme.style(:muted)
  defp token_style(_), do: Theme.style(:base)
end
