defmodule Beamcore.Gateway.Adapter do
  @moduledoc """
  Behaviour for platform adapters (Telegram, Discord, etc).

  Each adapter is a GenServer that connects to a messaging platform,
  receives messages, and routes them through the gateway session store.
  """

  @type chat_key :: binary()
  @type platform :: :telegram | :discord | :slack

  @type inbound_message :: %{
          chat_key: chat_key(),
          user_id: binary(),
          text: binary(),
          platform: platform()
        }

  @callback init(keyword()) :: {:ok, state :: any()} | {:stop, reason :: any()}
  @callback handle_inbound(inbound_message(), state :: any()) :: {:noreply, state :: any()}
  @callback send_message(chat_key(), binary(), keyword()) :: :ok | {:error, any()}
  @callback send_typing(chat_key()) :: :ok
  @callback platform_name() :: platform()
end
