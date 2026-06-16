defmodule Beamcore.TUI.Capability do
  @moduledoc """
  Startup capability checks for the primary TUI.
  """

  def supported?(opts \\ []) do
    cond do
      Keyword.has_key?(opts, :supported?) ->
        Keyword.fetch!(opts, :supported?)

      not Code.ensure_loaded?(ExRatatui) ->
        false

      not interactive?(opts) ->
        false

      true ->
        true
    end
  end

  def unsupported_reason(opts \\ []) do
    cond do
      not Code.ensure_loaded?(ExRatatui) -> "ex_ratatui is not available"
      not interactive?(opts) -> "stdin/stdout are not interactive TTYs"
      true -> "TUI startup failed"
    end
  end

  def unicode?(opts \\ []) do
    Keyword.get(opts, :unicode?, true)
  end

  def truecolor? do
    true
  end

  defp interactive?(opts) do
    Keyword.get_lazy(opts, :interactive?, fn ->
      IO.ANSI.enabled?()
    end)
  end
end
