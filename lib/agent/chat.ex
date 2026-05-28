defmodule Beamcore.Agent.Chat do
  @moduledoc """
  High-level chat orchestration.
  """

  alias Beamcore.Agent.Chat.{Loop, Session}
  alias Beamcore.Agent.Core.StatusBar

  @doc """
  Start chat.
  """
  def start() do
    StatusBar.setup(StatusBar)

    Beamcore.OpenAI.client()
    |> Session.new()
    |> Loop.start(StatusBar)
  end
end
