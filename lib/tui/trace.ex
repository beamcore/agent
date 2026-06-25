defmodule Beamcore.TUI.Trace do
  @moduledoc false

  @path "tmp/tui_trace.log"

  def enabled?, do: System.get_env("BEAMCORE_TUI_TRACE") in ["1", "true", "TRUE", "yes"]

  def message_type(%ExRatatui.Event.Key{}), do: :key
  def message_type(%ExRatatui.Event.Resize{}), do: :resize

  def message_type(event) when is_map(event) do
    cond do
      paste_event?(event) -> :paste
      true -> :event
    end
  end

  def message_type({:tick, _ref}), do: :tick
  def message_type(:load_file_finder_cache), do: :file_finder_load_request
  def message_type({:file_finder_cache, _files}), do: :file_finder_update
  def message_type({:system_mesh_snapshot, _ref, _snapshot}), do: :mesh_refresh
  def message_type({:provider_saved, _ref, _result}), do: :provider_save
  def message_type({:provider_action_done, _ref, _action, _result}), do: :provider_action
  def message_type({:runtime_event, _pid, _event}), do: :agent_stream_chunk
  def message_type({:agent_done, _pid, _session}), do: :agent_done
  def message_type({:agent_error, _pid, _error, _stacktrace}), do: :agent_error
  def message_type({:resize_redraw, _ref}), do: :resize_redraw
  def message_type({:refresh_session, _screen_type}), do: :refresh_session
  def message_type(_msg), do: :other_internal

  def event(stage, data \\ %{}) when is_atom(stage) and is_map(data) do
    if enabled?() do
      payload =
        data
        |> Map.put(:stage, stage)
        |> Map.put(:time_us, System.monotonic_time(:microsecond))
        |> Map.put(:mailbox_len, mailbox_len())
        |> Map.put_new(:pid, inspect(self()))

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

  defp paste_event?(event) do
    struct_name =
      event
      |> Map.get(:__struct__)
      |> case do
        nil -> ""
        module -> Atom.to_string(module)
      end

    String.ends_with?(struct_name, ".Paste") or Map.has_key?(event, :content) or
      Map.has_key?(event, "content")
  end
end
