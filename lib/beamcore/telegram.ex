defmodule Beamcore.Telegram do
  @moduledoc """
  Supervisor for the Telegram bot component.

  Starts the session manager and the polling bot.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    token = Keyword.get(opts, :token) || System.get_env("TELEGRAM_BOT_TOKEN")

    unless token do
      raise "Telegram bot token not configured. Set TELEGRAM_BOT_TOKEN env var."
    end

    children = [
      Beamcore.Telegram.SessionManager,
      {Beamcore.Telegram.Bot, token: token}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
