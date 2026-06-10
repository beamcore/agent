defmodule Beamcore.Agent.Tools.Eeva.IODevice do
  @moduledoc false
  use GenServer

  def start_link(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    GenServer.start_link(__MODULE__, max_bytes)
  end

  def output(pid), do: GenServer.call(pid, :output)

  @impl true
  def init(max_bytes) do
    {:ok, %{max_bytes: max_bytes, bytes: <<>>, truncated?: false}}
  end

  @impl true
  def handle_call(:output, _from, state) do
    suffix = if state.truncated?, do: "\n...[output truncated]", else: ""
    {:reply, safe_text(state.bytes, state.max_bytes) <> suffix, state}
  end

  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {reply, state} = handle_request(request, state)
    send(from, {:io_reply, reply_as, reply})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_request({:put_chars, chars}, state), do: append(chars, state)
  defp handle_request({:put_chars, _encoding, chars}, state), do: append(chars, state)

  defp handle_request({:put_chars, module, function, args}, state) do
    format_and_append(module, function, args, state)
  end

  defp handle_request({:put_chars, _encoding, module, function, args}, state) do
    format_and_append(module, function, args, state)
  end

  defp handle_request({:requests, requests}, state) when is_list(requests) do
    Enum.reduce_while(requests, {:ok, state}, fn request, {:ok, current} ->
      case handle_request(request, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {reply, next} -> {:halt, {reply, next}}
      end
    end)
  end

  defp handle_request({:get_geometry, :columns}, state), do: {{:ok, 120}, state}
  defp handle_request({:get_geometry, :rows}, state), do: {{:ok, 40}, state}
  defp handle_request({:setopts, _opts}, state), do: {:ok, state}
  defp handle_request(:getopts, state), do: {{:ok, []}, state}
  defp handle_request(_request, state), do: {{:error, :enotsup}, state}

  defp format_and_append(module, function, args, state) do
    try do
      module
      |> apply(function, args)
      |> append(state)
    rescue
      _ -> {{:error, :put_chars}, state}
    catch
      _, _ -> {{:error, :put_chars}, state}
    end
  end

  defp append(chars, state) do
    case to_binary(chars) do
      {:ok, binary} -> {:ok, append_binary(binary, state)}
      :error -> {{:error, :put_chars}, state}
    end
  end

  defp append_binary(_binary, %{truncated?: true} = state), do: state

  defp append_binary(binary, state) do
    remaining = state.max_bytes - byte_size(state.bytes)

    cond do
      remaining <= 0 ->
        %{state | truncated?: true}

      byte_size(binary) <= remaining ->
        %{state | bytes: state.bytes <> binary}

      true ->
        %{state | bytes: state.bytes <> binary_part(binary, 0, remaining), truncated?: true}
    end
  end

  defp safe_text(binary, max_bytes) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      prefix = "[binary output; base64 prefix]\n"
      encoded = Base.encode64(binary)
      remaining = max(max_bytes - byte_size(prefix), 0)
      prefix <> binary_part(encoded, 0, min(byte_size(encoded), remaining))
    end
  end

  defp to_binary(chars) when is_binary(chars), do: {:ok, chars}

  defp to_binary(chars) do
    case :unicode.characters_to_binary(chars) do
      binary when is_binary(binary) -> {:ok, binary}
      _ -> :error
    end
  rescue
    _ -> :error
  end
end
