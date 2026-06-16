defmodule Beamcore.TUI.State.WaitStatus do
  @moduledoc false

  def set(state, event) do
    wait_ms = normalize_wait_ms(Map.get(event, :wait_ms))
    now_ms = Map.get(event, :now_ms, System.monotonic_time(:millisecond))
    reason = Map.get(event, :reason, :unknown)
    message = Map.get(event, :message)

    %{
      state
      | status: :rate_limited,
        wait_status: %{
          reason: reason,
          wait_ms: wait_ms,
          started_ms: now_ms,
          retry_at_ms: now_ms + wait_ms,
          message: message
        }
    }
    |> Beamcore.TUI.State.mark_dirty()
  end

  def clear(state), do: %{state | wait_status: nil} |> Beamcore.TUI.State.mark_dirty()

  def tick(state, now_ms) do
    case state.wait_status do
      %{retry_at_ms: retry_at} = ws when now_ms >= retry_at ->
        %{state | wait_status: %{ws | wait_ms: 0, retry_at_ms: now_ms}}

      %{retry_at_ms: retry_at} = ws ->
        remaining = retry_at - now_ms
        %{state | wait_status: %{ws | wait_ms: remaining}}

      _ ->
        state
    end
  end

  def text(%{wait_status: %{reason: reason, retry_at_ms: retry_at}}, now_ms) do
    remaining = remaining_seconds(retry_at, now_ms)
    label = wait_label(reason)
    "#{label} · retrying in #{remaining}s"
  end

  def text(_, _), do: nil

  defp wait_label(:rate_limit), do: "Rate limited"
  defp wait_label(:cooldown), do: "Cooling down"
  defp wait_label(:backoff), do: "Waiting for provider"
  defp wait_label(:retry_wait), do: "Retrying soon"
  defp wait_label(_reason), do: "Waiting for provider"

  defp normalize_wait_ms(wait_ms) when is_integer(wait_ms), do: max(wait_ms, 0)
  defp normalize_wait_ms(_wait_ms), do: 0

  defp remaining_seconds(retry_at_ms, now_ms) do
    retry_at_ms
    |> Kernel.-(now_ms)
    |> max(0)
    |> Kernel.+(999)
    |> div(1000)
  end
end
