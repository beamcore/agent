defmodule Beamcore.TUI.Components.System.Store do
  @moduledoc false

  @stats_key :provider_token_stats

  def load do
    case Beamcore.Config.get(@stats_key) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  def record_usage(_provider, nil, nil), do: :ok
  def record_usage(_provider, 0, 0), do: :ok

  def record_usage(provider, input, output) when is_binary(provider) do
    stats = load()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    current = Map.get(stats, provider, %{})
    cur_input = Map.get(current, "input_tokens", 0) || 0
    cur_output = Map.get(current, "output_tokens", 0) || 0

    updated =
      Map.put(stats, provider, %{
        "input_tokens" => cur_input + (input || 0),
        "output_tokens" => cur_output + (output || 0),
        "total_tokens" => cur_input + (input || 0) + cur_output + (output || 0),
        "last_used" => now
      })

    Beamcore.Config.put(@stats_key, Jason.encode!(updated))
  end

  def record_usage(_provider, _input, _output), do: :ok
end
