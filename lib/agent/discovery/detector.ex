defmodule Beamcore.Agent.Discovery.Detector do
  @moduledoc """
  Scans the working directory to detect the project nature/language support.
  """

  @doc """
  Detects the project nature. Returns :elixir, :erlang, or :unknown.
  """
  def detect(dir \\ File.cwd!()) do
    cond do
      mix_project?(dir) -> :elixir
      erlang_project?(dir) -> :erlang
      true -> :unknown
    end
  end

  defp mix_project?(dir) do
    File.exists?(Path.join(dir, "mix.exs"))
  end

  defp erlang_project?(dir) do
    File.exists?(Path.join(dir, "rebar.config")) or
      File.exists?(Path.join(dir, "erlang.mk"))
  end
end
