defmodule Beamcore.Agent.Chat.RateLimit do
  @moduledoc false

  @default_wait_seconds 15

  def default_wait_ms, do: @default_wait_seconds * 1000

  def retry_after_ms(error) do
    case retry_after_seconds(error) do
      seconds when is_integer(seconds) and seconds > 0 -> seconds * 1000
      _ -> nil
    end
  end

  def retry_after_seconds(error) do
    [
      retry_after_from_headers(error),
      retry_after_from_body(error),
      retry_after_from_message(error)
    ]
    |> Enum.find(&positive_integer?/1)
  end

  def message(error) do
    case retry_after_seconds(error) do
      seconds when is_integer(seconds) and seconds > 0 ->
        "Provider rate limit reached. Wait about #{format_duration(seconds)}, then retry."

      _ ->
        "Provider rate limit reached. Wait a bit, then retry."
    end
  end

  defp retry_after_from_headers(error) do
    error
    |> headers()
    |> Enum.find_value(fn {key, value} ->
      if normalize_header_key(key) == "retry-after" do
        parse_retry_after(value)
      end
    end)
  end

  defp retry_after_from_body(%OpenaiEx.Error{body: body}), do: retry_after_from_body(body)

  defp retry_after_from_body(%{} = body) do
    ["retry_after", "retry-after", "retryAfter", :retry_after, :"retry-after", :retryAfter]
    |> Enum.find_value(fn key -> parse_retry_after(Map.get(body, key)) end)
  end

  defp retry_after_from_body(_body), do: nil

  defp retry_after_from_message(%OpenaiEx.Error{message: message}) when is_binary(message) do
    with [_, value] <- Regex.run(~r/retry[- ]after[:= ]+(\d+)/i, message) do
      parse_retry_after(value)
    end
  end

  defp retry_after_from_message(_error), do: nil

  defp headers(error) when is_map(error) do
    cond do
      is_list(Map.get(error, :headers)) ->
        Map.get(error, :headers)

      is_map(Map.get(error, :response)) and is_list(Map.get(Map.get(error, :response), :headers)) ->
        Map.get(Map.get(error, :response), :headers)

      true ->
        []
    end
  end

  defp headers(_error), do: []

  defp normalize_header_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_header_key()

  defp normalize_header_key(key) when is_binary(key), do: String.downcase(key)

  defp normalize_header_key(key) when is_list(key),
    do: key |> IO.iodata_to_binary() |> String.downcase()

  defp normalize_header_key(_key), do: ""

  defp parse_retry_after(value) when is_integer(value), do: value
  defp parse_retry_after(value) when is_float(value), do: ceil(value)

  defp parse_retry_after(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _ -> parse_http_date(value)
    end
  end

  defp parse_retry_after(value) when is_list(value),
    do: value |> IO.iodata_to_binary() |> parse_retry_after()

  defp parse_retry_after(_value), do: nil

  defp parse_http_date(value) do
    try do
      value
      |> String.to_charlist()
      |> :httpd_util.convert_request_date()
      |> case do
        :undefined ->
          nil

        {{year, month, day}, {hour, minute, second}} ->
          {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
          target = DateTime.from_naive!(naive, "Etc/UTC")
          max(DateTime.diff(target, DateTime.utc_now(), :second), 0)
      end
    rescue
      _error -> nil
    catch
      _kind, _reason -> nil
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds} seconds"

  defp format_duration(seconds) do
    minutes = div(seconds + 59, 60)
    "#{minutes} minute#{if minutes == 1, do: "", else: "s"}"
  end

  defp positive_integer?(value), do: is_integer(value) and value > 0
end
