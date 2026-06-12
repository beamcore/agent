defmodule Beamcore.Agent.RuntimeRateLimitTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.Chat.{ModeSettings, Session, ToolRuntime}
  alias Beamcore.Agent.Runtime

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{"MISTRAL_API_KEY" => "test-api-key"})

    previous_mock = Application.get_env(:agent, :mock_completions_create)
    previous_wait = Application.get_env(:agent, :rate_limit_retry_wait_ms)
    Application.put_env(:agent, :rate_limit_retry_wait_ms, 5)

    on_exit(fn ->
      restore_env(:mock_completions_create, previous_mock)
      restore_env(:rate_limit_retry_wait_ms, previous_wait)
    end)

    :ok
  end

  test "rate limit is a waiting state and the pending turn continues" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    Application.put_env(:agent, :mock_completions_create, fn _client, _params ->
      attempt = Agent.get_and_update(counter, fn value -> {value + 1, value + 1} end)
      send(parent, {:provider_attempt, attempt})

      if attempt == 1 do
        {:error, %OpenaiEx.Error{kind: :rate_limit, status_code: 429}}
      else
        {:ok, %{"choices" => [%{"message" => %{"role" => "assistant", "content" => "ok"}}]}}
      end
    end)

    tmp_dir = Path.join(System.tmp_dir!(), "beamcore-runtime-rate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    mode_settings = %ModeSettings{
      mode: :chat,
      provider: "mistral",
      model: "mistral-medium-3-5",
      retry_limit: 0
    }

    session =
      Beamcore.Provider.Registry.client()
      |> Session.new(
        session_id: "runtime-rate-limit",
        screen_type: :chat,
        workspace_root: tmp_dir
      )
      |> Map.put(:mode_settings, mode_settings)
      |> Map.put(:log_file, Path.join(tmp_dir, "session.json"))
      |> Map.put(:state_file, Path.join(tmp_dir, "session.state.json"))
      |> Map.put(:checkpoint_file, Path.join(tmp_dir, "session.checkpoints.json"))

    {:ok, runtime} = Runtime.start_link(tui_pid: self())
    Runtime.send_message(runtime, session, "hello", ToolRuntime.default())

    assert_receive {:provider_attempt, 1}, 1_000

    assert_receive {:runtime_event, ^runtime,
                    {:execution_stopped, %{reason: :rate_limited, recoverable?: true}}},
                   1_000

    assert_receive {:runtime_event, ^runtime, {:status, :rate_limited}}, 1_000
    assert_receive {:provider_attempt, 2}, 1_000
    assert_receive {:runtime_event, ^runtime, {:assistant, "ok"}}, 1_000
    assert_receive {:agent_done, ^runtime, final_session}, 1_000

    user_messages = Enum.filter(final_session.messages, &(&1[:role] == "user" or &1["role"] == "user"))
    assert length(user_messages) == 1
  end

  defp restore_env(key, nil), do: Application.delete_env(:agent, key)
  defp restore_env(key, value), do: Application.put_env(:agent, key, value)
end
