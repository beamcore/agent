defmodule Beamcore.TUI.Components.Chat.SyntaxHighlight do
  @moduledoc false

  alias ExRatatui.Text.{Line, Span}

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

  def highlight_line(line, max_len) do
    line
    |> tokenize()
    |> limit_length(max_len)
    |> to_spans()
  end

  defp tokenize(line) do
    tokenize(to_string(line), [])
  end

  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(str, acc) do
    cond do
      match = Regex.run(@whitespace_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:whitespace, val} | acc])

      match = Regex.run(@comment_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:comment, val} | acc])

      match = Regex.run(@string_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:string, val} | acc])

      match = Regex.run(@atom_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:atom, val} | acc])

      match = Regex.run(@atom_key_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:atom, val} | acc])

      match = Regex.run(@keyword_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:keyword, val} | acc])

      match = Regex.run(@module_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:module, val} | acc])

      match = Regex.run(@number_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:number, val} | acc])

      match = Regex.run(@identifier_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:identifier, val} | acc])

      match = Regex.run(@operator_rx, str) ->
        val = List.first(match)
        tokenize(String.slice(str, String.length(val)..-1//1), [{:operator, val} | acc])

      true ->
        case String.next_grapheme(str) do
          {char, rest} -> tokenize(rest, [{:text, char} | acc])
          nil -> Enum.reverse(acc)
        end
    end
  end

  defp limit_length(tokens, max_len) do
    limit_length(tokens, max_len, [])
  end

  defp limit_length([], _max_len, acc), do: Enum.reverse(acc)

  defp limit_length([{type, content} | rest], max_len, acc) do
    len = String.length(content)

    cond do
      max_len <= 0 ->
        Enum.reverse(acc)

      len <= max_len ->
        limit_length(rest, max_len - len, [{type, content} | acc])

      true ->
        truncated = String.slice(content, 0, max(max_len - 1, 0)) <> "\u2026"
        Enum.reverse([{type, truncated} | acc])
    end
  end

  defp to_spans(tokens) do
    case tokens do
      [] ->
        [%Span{content: "  ", style: %ExRatatui.Style{}}]

      [{type, first} | rest] ->
        first_span = %Span{content: "  " <> first, style: style(type)}

        other_spans =
          Enum.map(rest, fn {type, content} ->
            %Span{content: content, style: style(type)}
          end)

        [first_span | other_spans]
    end
    |> then(&%Line{spans: &1})
  end

  defp style(:keyword), do: %ExRatatui.Style{fg: :cyan, modifiers: [:bold]}
  defp style(:comment), do: %ExRatatui.Style{fg: :dark_gray, modifiers: [:dim]}
  defp style(:string), do: %ExRatatui.Style{fg: :green}
  defp style(:atom), do: %ExRatatui.Style{fg: :cyan}
  defp style(:number), do: %ExRatatui.Style{fg: :yellow}
  defp style(:module), do: %ExRatatui.Style{fg: :yellow, modifiers: [:bold]}
  defp style(:operator), do: %ExRatatui.Style{fg: :dark_gray}
  defp style(_), do: %ExRatatui.Style{}
end
