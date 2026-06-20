defmodule Beamcore.AppLog do
  @moduledoc """
  Small append-only application log for diagnostics that should stay outside
  the TUI and outside model context.
  """

  @sensitive_key ~r/(api[_-]?key|authorization|bearer|token|password|passwd|secret|cookie|session)/i
  @bearer_secret ~r/Bearer\s+[^\s]+/
  @authorization_secret ~r/\bAuthorization\s*:\s*(?!Bearer\s+)[^\s,;]+/i
  @token_secret ~r/\b(?:sk|key|tok|pat)-[A-Za-z0-9_\-]{12,}\b/
  @sensitive_assignment ~r/\b(api[_-]?key|token|password|passwd|secret|cookie)\s*[:=]\s*([^\s,;]+)/i
  @max_value_chars 4_000

  @spec log_path(Date.t()) :: binary()
  def log_path(date \\ Date.utc_today()) do
    Path.join(log_dir(), Date.to_iso8601(date) <> ".txt")
  end

  @spec log_dir() :: binary()
  def log_dir do
    Application.get_env(:beamcore, :app_log_dir) ||
      Path.join([System.user_home!(), ".beamcore", "logs"])
  end

  @spec user_message() :: binary()
  def user_message, do: "Application error. See #{log_path()} for details."

  def info(message, metadata \\ []), do: write(:info, message, metadata)
  def warn(message, metadata \\ []), do: write(:warn, message, metadata)
  def error(message, metadata \\ []), do: write(:error, message, metadata)

  def exception(kind, reason, stacktrace, metadata \\ []) do
    formatted = Exception.format(kind, reason, stacktrace)
    write(:error, formatted, metadata)
  end

  defp write(level, message, metadata) do
    try do
      line = format_line(level, message, metadata)
      File.mkdir_p!(log_dir())
      File.write!(log_path(), line, [:append])
      :ok
    rescue
      _ ->
        :ok
    catch
      _, _ ->
        :ok
    end
  end

  defp format_line(level, message, metadata) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    metadata = metadata |> Enum.into(%{}) |> redact()

    metadata_text =
      if map_size(metadata) == 0,
        do: "",
        else: " " <> inspect(metadata, limit: 20, printable_limit: 2_000)

    "[#{timestamp}] #{String.upcase(to_string(level))} #{redact_text(to_string(message))}#{metadata_text}\n"
  end

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.map(list, fn {key, value} ->
        if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(value)}
      end)
    else
      Enum.map(list, &redact/1)
    end
  end

  defp redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact() |> List.to_tuple()

  defp redact(value) when is_binary(value) do
    value
    |> redact_text()
    |> truncate_value()
  end

  defp redact(value), do: value

  defp sensitive_key?(key), do: Regex.match?(@sensitive_key, to_string(key))

  defp redact_text(text) do
    text
    |> replace_regex(@bearer_secret, "Bearer [REDACTED]")
    |> replace_regex(@authorization_secret, "Authorization: [REDACTED]")
    |> replace_regex(@token_secret, "[REDACTED]")
    |> replace_regex(@sensitive_assignment, "\\1=[REDACTED]")
  end

  defp replace_regex(text, regex, replacement), do: Regex.replace(regex, text, replacement)

  defp truncate_value(value) do
    if String.length(value) <= @max_value_chars do
      value
    else
      String.slice(value, 0, @max_value_chars) <> "…"
    end
  end
end
