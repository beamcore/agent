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

      not terminal_capable?(opts) ->
        false

      true ->
        true
    end
  end

  def unsupported_reason(opts \\ []) do
    cond do
      not Code.ensure_loaded?(ExRatatui) -> "ex_ratatui is not available"
      not interactive?(opts) -> "stdin/stdout are not interactive TTYs"
      not terminal_capable?(opts) -> "terminal type is unsupported"
      true -> "TUI startup failed"
    end
  end

  def unicode?(opts \\ []) do
    Keyword.get(opts, :unicode?, System.get_env("BEAMCORE_ASCII_TUI") != "1")
  end

  def truecolor? do
    System.get_env("COLORTERM") in ["truecolor", "24bit"]
  end

  defp interactive?(opts) do
    Keyword.get_lazy(opts, :interactive?, fn ->
      IO.ANSI.enabled?() and System.get_env("TERM") not in [nil, "", "dumb"]
    end)
  end

  defp terminal_capable?(opts) do
    term = Keyword.get(opts, :term, System.get_env("TERM") || "")
    term not in ["", "dumb"]
  end
end
