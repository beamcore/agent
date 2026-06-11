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
        case Beamcore.Provider.Registry.validate_selection(Beamcore.Config.active_provider()) do
          {:ok, _provider} ->
            nil

          {:error, _reason} ->
            IO.puts(Beamcore.Provider.Registry.missing_config_message())
            nil
        end
    end
  end
end
