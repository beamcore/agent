defmodule Beamcore.Gateway do
  @moduledoc """
  Gateway supervisor.

  Starts the session store and all configured platform adapters.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    telegram_token = Keyword.get(opts, :telegram_token) || System.get_env("TELEGRAM_BOT_TOKEN")
    discord_token = Keyword.get(opts, :discord_token) || System.get_env("DISCORD_BOT_TOKEN")

    children =
      [Beamcore.Gateway.SessionStore] ++
        telegram_children(telegram_token) ++
        discord_children(discord_token)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp telegram_children(nil), do: []
  defp telegram_children(""), do: []

  defp telegram_children(token) do
    [{Beamcore.Gateway.Adapters.Telegram, token: token}]
  end

  defp discord_children(nil), do: []
  defp discord_children(""), do: []

  defp discord_children(token) do
    Application.put_env(:nostrum, :token, token)
    Application.ensure_all_started(:nostrum)
    [Beamcore.Gateway.Adapters.Discord]
  end
end
