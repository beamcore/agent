defmodule Beamcore.TUI.NumberFormat do
  @moduledoc false

  def compact(nil), do: "0"
  def compact(0), do: "0"
  def compact(value) when is_integer(value) and value < 0, do: "-" <> compact(abs(value))

  # < 1,000: exact
  def compact(value) when is_integer(value) and value < 1_000 do
    Integer.to_string(value)
  end

  # 1k – 10k: one decimal (e.g. 2.3k)
  def compact(value) when is_integer(value) and value < 10_000 do
    format_scaled(value, 1_000, 1) <> "k"
  end

  # 10k – 1M: rounded k (e.g. 45k)
  def compact(value) when is_integer(value) and value < 1_000_000 do
    Integer.to_string(div(value, 1_000)) <> "k"
  end

  # 1M – 10M: one decimal M (e.g. 1.2M)
  def compact(value) when is_integer(value) and value < 10_000_000 do
    format_scaled(value, 1_000_000, 1) <> "M"
  end

  # ≥ 10M: rounded M (e.g. 12M)
  def compact(value) when is_integer(value) do
    Integer.to_string(div(value, 1_000_000)) <> "M"
  end

  def compact(value), do: to_string(value)

  defp format_scaled(value, scale, decimals) do
    scaled = value / scale

    :erlang.float_to_binary(scaled, decimals: decimals)
    |> String.trim_trailing(".0")
  end
end
