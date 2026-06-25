defmodule Beamcore.TUI.Trace do
  @moduledoc false

  @path "tmp/tui_trace.log"

  def enabled?, do: System.get_env("BEAMCORE_TUI_TRACE") in ["1", "true", "TRUE", "yes"]

  def event(stage, data \\ %{}) when is_atom(stage) and is_map(data) do
    if enabled?() do
      payload =
        data
        |> Map.put(:stage, stage)
        |> Map.put(:time_us, System.monotonic_time(:microsecond))
        |> Map.put(:mailbox_len, mailbox_len())

      append(payload)
    end

    :ok
  end

  defp append(payload) do
    File.mkdir_p!(Path.dirname(@path))
    File.write!(@path, inspect(payload, printable_limit: 1_000) <> "\n", [:append])
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp mailbox_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> nil
    end
  end
end
