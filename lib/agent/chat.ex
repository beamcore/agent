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
    if Mix.env() == :test do
      {:ok, nil}
    else
      {:ok, pid} = StatusBar.start_link()
      StatusBar.setup(pid)

      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Loop.start(pid)
    end
  end
end
