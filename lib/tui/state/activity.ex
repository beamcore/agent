defmodule Beamcore.TUI.State.Activity do
  @moduledoc false

  alias Beamcore.Agent.Core.ToolDisplay

  @max_activity 500

  def add_activity(state, name, args, status \\ :queued) do
    event = compact_activity(name, args, status)

    %{state | activity: Enum.take([event | state.activity], @max_activity)}
    |> Beamcore.TUI.State.mark_dirty()
  end

  def update_activity(state, name, args, result) do
    event = compact_activity(name, args, ToolDisplay.result_status(result), result)

    activity =
      case state.activity do
        [%{name: ^name, target: target} = latest | rest] when target == event.target ->
          [Map.merge(latest, event) | rest]

        other ->
          [event | other]
      end

    %{state | activity: Enum.take(activity, @max_activity)}
    |> Beamcore.TUI.State.mark_dirty()
  end

  def compact_activity(name, args, status, result \\ nil) do
    display = ToolDisplay.activity(name, args, status, result)

    %{
      id: System.unique_integer([:positive]),
      timestamp_ms: System.system_time(:millisecond),
      name: display.name,
      target: display.target,
      status: display.status,
      label: display.label,
      summary: display.summary,
      result: compact_activity_result(result),
      args: compact_args(args)
    }
  end

  def compact_args(args) when is_map(args) do
    args
    |> Enum.map(fn {key, val} ->
      val_compact =
        cond do
          is_binary(val) ->
            if String.length(val) > 60 do
              String.slice(val, 0, 57) <> "..."
            else
              val
            end

          is_map(val) ->
            compact_args(val)

          is_list(val) ->
            Enum.map(val, fn
              item when is_map(item) ->
                compact_args(item)

              item when is_binary(item) ->
                if String.length(item) > 60, do: String.slice(item, 0, 57) <> "...", else: item

              item ->
                item
            end)

          true ->
            val
        end

      {key, val_compact}
    end)
    |> Map.new()
  end

  def compact_args(args), do: args

  defp compact_activity_result(nil), do: nil

  defp compact_activity_result(result) when is_binary(result) do
    ToolDisplay.compact_text(result, 1_200)
  end

  defp compact_activity_result(result) do
    result
    |> inspect(pretty: false, limit: 16, printable_limit: 1_000)
    |> ToolDisplay.compact_text(1_200)
  end
end
