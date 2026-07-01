defmodule Beamcore.TUI.NumberFormat do
  @moduledoc false

  @suffixes [
    {1_000_000_000_000, "T"},
    {1_000_000_000, "B"},
    {1_000_000, "M"},
    {1_000, "K"}
  ]

  def compact(nil), do: "0"
  def compact(value) when is_integer(value) and value < 0, do: "-" <> compact(abs(value))
  def compact(value) when is_integer(value) and value < 1_000, do: Integer.to_string(value)

  def compact(value) when is_integer(value) do
    {scale, suffix} = Enum.find(@suffixes, fn {scale, _suffix} -> value >= scale end)
    scaled = value / scale
    formatted = :erlang.float_to_binary(scaled, decimals: 1) |> String.trim_trailing(".0")
    formatted <> suffix
  end

  def compact(value), do: to_string(value)
end
