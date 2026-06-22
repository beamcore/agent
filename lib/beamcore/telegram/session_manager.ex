defmodule Beamcore.Telegram.SessionManager do
  @moduledoc """
  Manages per-user session workers via Registry + DynamicSupervisor.
  """

  alias Beamcore.Telegram.SessionWorker

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  def start_link do
    children = [
      {Registry, keys: :unique, name: Beamcore.Telegram.SessionRegistry},
      {DynamicSupervisor, name: Beamcore.Telegram.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def get_or_create(client, chat_id, user_id) do
    case Registry.lookup(Beamcore.Telegram.SessionRegistry, user_id) do
      [{pid, _}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: start_worker(client, chat_id, user_id)

      [] ->
        start_worker(client, chat_id, user_id)
    end
  end

  defp start_worker(client, chat_id, user_id) do
    spec = {SessionWorker, client: client, chat_id: chat_id, user_id: user_id}

    case DynamicSupervisor.start_child(Beamcore.Telegram.SessionSupervisor, spec) do
      {:ok, pid} ->
        Registry.register(Beamcore.Telegram.SessionRegistry, user_id, pid)
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
