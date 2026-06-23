defmodule Beamcore.Gateway.Adapters.Discord do
  @moduledoc """
  Discord adapter via Nostrum. Delegates commands and turn logic
  to Gateway.Commands and Gateway.Turn.
  """

  use Nostrum.Consumer

  alias Beamcore.Gateway.{Commands, Turn}
  alias Nostrum.Api.{Message, Channel}

  # -- Consumer ----------------------------------------------------------------

  @impl true
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    unless msg.author.bot or msg.content == "" do
      handle_message(
        msg.content,
        "discord:#{msg.channel_id}",
        to_string(msg.author.id),
        msg.channel_id
      )
    end
  end

  def handle_event(_), do: :ignore

  # -- Message routing ---------------------------------------------------------

  defp handle_message(text, chat_key, user_id, channel_id) do
    cond do
      text == "/myid" ->
        Message.create(channel_id, "Your Discord ID: #{user_id}")

      true ->
        case Commands.route(text, chat_key) do
          {:command, :cancel} ->
            case Turn.cancel(chat_key) do
              :ok -> Message.create(channel_id, "Stopped.")
              :not_running -> Message.create(channel_id, "Nothing running.")
            end

          {:command, response} ->
            Message.create(channel_id, response)

          {:api, parts} ->
            Message.create(channel_id, Commands.exec_api(parts))

          {:message, text} ->
            typing_fn = fn -> Channel.start_typing(channel_id) end
            Turn.dispatch(chat_key, :discord, text, fn _ch, _txt -> :ok end, typing_fn)
        end
    end
  end

  # -- Gateway events (receive via parent process) -----------------------------

  def handle_gateway_event(_chat_key, event, channel_id) do
    case Turn.format_event(event) do
      {:text, text} -> Message.create(channel_id, text)
      {:code, code} -> Message.create(channel_id, "```\n#{code}\n```")
      {:error_code, code} -> Message.create(channel_id, "Error:\n```\n#{code}\n```")
      {:error, msg} -> Message.create(channel_id, "Error: #{msg}")
      :typing -> Channel.start_typing(channel_id)
      :ignore -> :ok
    end
  end
end
