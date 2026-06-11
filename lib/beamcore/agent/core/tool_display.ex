defmodule Beamcore.Agent.Core.ToolDisplay do
  @moduledoc """
  Presentation helpers for the single Eeva execution surface.
  """

  @default_limit 180

  def activity(name, args, status, result \\ nil) do
    name = to_string(name)

    %{
      name: name,
      target: target(name, args),
      status: status,
      label: label(name, args, status),
      summary: summary(name, args, result),
      result: result_summary(result)
    }
  end

  def label("eeva", args, :blocked), do: "blocked " <> label("eeva", args, :done)

  def label("eeva", args, _status) do
    code = args |> Map.get("code", "") |> first_code_line()
    compact_join(["eeva", code]) || "eeva"
  end

  def label(name, _args, _status), do: to_string(name)

  def blocked_label(name, args, _target \\ nil), do: label(to_string(name), args, :blocked)

  def target("eeva", _args), do: "Elixir"
  def target(_name, _args), do: nil

  def summary("eeva", args, result) do
    code = args |> Map.get("code", "") |> first_code_line()
    compact_join([code, result_summary(result)]) |> compact_text()
  end

  def summary(_name, _args, result), do: result_summary(result)

  def result_status(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"ok" => false, "classification" => classification}}
      when classification in ["policy", "blocked"] ->
        :blocked

      {:ok, %{"ok" => false}} ->
        :error

      _ ->
        if String.starts_with?(String.trim_leading(result), "Error:"), do: :error, else: :done
    end
  end

  def result_status(_), do: :done

  def result_summary(nil), do: ""

  def result_summary(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"summary" => summary}} -> compact_text(summary)
      _ -> compact_text(result)
    end
  end

  def result_summary(result), do: compact_text(inspect(result, limit: 4, printable_limit: 160))

  def compact_text(text, limit \\ @default_limit)
  def compact_text(nil, _limit), do: ""

  def compact_text(text, limit) when is_binary(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > limit do
      String.slice(text, 0, max(limit - 3, 0)) <> "..."
    else
      text
    end
  end

  def compact_text(value, limit), do: value |> to_string() |> compact_text(limit)

  # Kept as tiny public compatibility helpers for Pretty. They no longer encode
  # separate tool semantics.
  def byte_badge(args) do
    case Map.get(args, "content") do
      content when is_binary(content) and content != "" -> "(#{byte_size(content)} bytes)"
      _ -> nil
    end
  end

  def modify_badge(_args), do: nil

  defp first_code_line(code) do
    code
    |> to_string()
    |> String.split(~r/\R/, parts: 2)
    |> List.first()
    |> compact_text(92)
  end

  defp compact_join(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end
end
