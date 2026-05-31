defmodule Beamcore.Agent.Chat do
  @moduledoc """
  High-level chat orchestration.
  """

  alias Beamcore.Agent.Chat.{Loop, Session}
  alias Beamcore.Agent.Core.StatusBar

  @doc """
  Start chat.
  """
  def start(opts \\ []) do
    StatusBar.setup(StatusBar)

    opts
    |> client()
    |> Session.new(opts)
    |> Loop.start(StatusBar)
  end

  defp client(opts) do
    case Keyword.fetch(opts, :client) do
      {:ok, client} ->
        client

      :error ->
        if Beamcore.OpenAI.configured?() do
          Beamcore.OpenAI.client()
        else
          IO.puts(Beamcore.OpenAI.missing_config_message())
          nil
        end
    end
  end
end
