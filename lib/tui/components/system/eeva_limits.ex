defmodule Beamcore.TUI.Components.System.EevaLimits do
  @moduledoc "Visible Eeva execution limits for the F3 system screen."

  alias Beamcore.Agent.Tools.Eeva
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  @spec lines() :: [Line.t()]
  def lines do
    limits = Eeva.limits()

    [
      line("timeout", format_ms(limits.timeout_ms)),
      line("memory", format_bytes(limits.max_memory_bytes)),
      line("reductions", format_count(limits.max_reductions)),
      line("output", format_bytes(limits.max_output_bytes)),
      line("result", format_bytes(limits.max_result_bytes)),
      line("code", format_bytes(limits.max_code_bytes)),
      line("payload", format_bytes(limits.max_payload_bytes)),
      line("ast", format_count(limits.max_ast_nodes))
    ]
  end

  defp line(label, value) do
    %Line{
      spans: [
        %Span{content: "  #{String.pad_trailing(label, 10)}", style: Theme.style(:muted)},
        %Span{content: value, style: Theme.style(:base)}
      ]
    }
  end

  defp format_ms(ms) when is_integer(ms) and rem(ms, 1_000) == 0, do: "#{div(ms, 1_000)}s"
  defp format_ms(ms) when is_integer(ms), do: "#{ms}ms"
  defp format_ms(value), do: to_string(value)

  defp format_bytes(bytes) when is_integer(bytes) and rem(bytes, 1_048_576) == 0,
    do: "#{div(bytes, 1_048_576)}MiB"

  defp format_bytes(bytes) when is_integer(bytes) and rem(bytes, 1_024) == 0,
    do: "#{div(bytes, 1_024)}KiB"

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes}B"
  defp format_bytes(value), do: to_string(value)

  defp format_count(count) when is_integer(count), do: Beamcore.TUI.NumberFormat.compact(count)
  defp format_count(value), do: to_string(value)
end
