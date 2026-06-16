defmodule Beamcore.Provider.Usage do
  @moduledoc """
  Provider-neutral token usage accounting.
  """

  defstruct input_tokens: nil,
            output_tokens: nil,
            total_tokens: nil,
            cached_tokens: nil,
            reasoning_tokens: nil,
            source: :unknown

  @type source :: :provider_reported | :estimated | :unknown

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          cached_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          source: source()
        }

  def from_response(%{"usage" => usage}) when is_map(usage), do: from_map(usage)
  def from_response(%{usage: usage}) when is_map(usage), do: from_map(usage)
  def from_response(_response), do: unknown()

  def from_map(usage) when is_map(usage) do
    input = int(usage, "prompt_tokens") || int(usage, "input_tokens")
    output = int(usage, "completion_tokens") || int(usage, "output_tokens")
    total = int(usage, "total_tokens") || maybe_total(input, output)

    cached =
      int(usage, "cached_tokens") ||
        get_in_int(usage, ["prompt_tokens_details", "cached_tokens"]) ||
        get_in_int(usage, [:prompt_tokens_details, :cached_tokens])

    reasoning =
      int(usage, "reasoning_tokens") ||
        get_in_int(usage, ["completion_tokens_details", "reasoning_tokens"]) ||
        get_in_int(usage, [:completion_tokens_details, :reasoning_tokens])

    source =
      if Enum.any?([input, output, total, cached, reasoning], &is_integer/1),
        do: :provider_reported,
        else: :unknown

    %__MODULE__{
      input_tokens: input,
      output_tokens: output,
      total_tokens: total,
      cached_tokens: cached,
      reasoning_tokens: reasoning,
      source: source
    }
  end

  defp unknown, do: %__MODULE__{}

  def to_raw_usage(%__MODULE__{} = usage) do
    %{
      "prompt_tokens" => usage.input_tokens || 0,
      "completion_tokens" => usage.output_tokens || 0,
      "total_tokens" => usage.total_tokens || 0
    }
  end

  def to_safe_map(%__MODULE__{} = usage) do
    %{
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens,
      total_tokens: usage.total_tokens,
      cached_tokens: usage.cached_tokens,
      reasoning_tokens: usage.reasoning_tokens,
      source: usage.source
    }
  end

  defp int(map, key) do
    value = Map.get(map, key) || Map.get(map, String.to_atom(key))

    if is_integer(value) and value >= 0, do: value, else: nil
  end

  defp get_in_int(map, path) do
    value = get_in(map, path)
    if is_integer(value) and value >= 0, do: value, else: nil
  end

  defp maybe_total(input, output) when is_integer(input) and is_integer(output),
    do: input + output

  defp maybe_total(_input, _output), do: nil
end
