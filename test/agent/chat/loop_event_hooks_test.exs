defmodule Beamcore.Agent.Chat.LoopEventHooksTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Beamcore.Agent.Chat.{Loop, Session}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })

    Process.delete(:mock_completions_create)

    on_exit(fn ->
      Process.delete(:mock_completions_create)
      Process.delete(:mock_completions_calls)
    end)

    %{session: Beamcore.OpenAI.client() |> Session.new()}
  end

  test "event handler exceptions do not alter the returned session", %{session: session} do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "Done."}}
         ]
       }}
    end)

    log =
      capture_log([level: :debug], fn ->
        output =
          capture_io(fn ->
            updated =
              Loop.send_message(session, "hello", nil, nil,
                event_handler: fn _event -> raise "presentation failed" end
              )

            assert Enum.map(updated.messages, &(&1[:role] || &1["role"])) == [
                     "system",
                     "user",
                     "assistant"
                   ]
          end)

        assert output =~ "Done."
      end)

    assert log =~ "TUI event handler failed for :status"
  end

  test "silent mode suppresses printing only and still updates usage", %{session: session} do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok,
       %{
         "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15},
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "Quiet result."}}
         ]
       }}
    end)

    output =
      capture_io(fn ->
        updated = Loop.send_message(session, "hello", nil, nil, silent: true)
        assert updated.last_prompt_tokens == 12
        assert updated.total_tokens == 15
        assert List.last(updated.messages)["content"] == "Quiet result."
      end)

    assert output == ""
  end

  test "TUI events do not duplicate assistant messages in history", %{session: session} do
    Process.put(:mock_completions_create, fn _client, _params ->
      {:ok,
       %{
         "choices" => [
           %{"message" => %{"role" => "assistant", "content" => "Single response."}}
         ]
       }}
    end)

    parent = self()

    updated =
      Loop.send_message(session, "hello", nil, nil,
        silent: true,
        event_handler: fn event -> send(parent, {:event, event}) end
      )

    assistant_messages =
      Enum.filter(updated.messages, fn message ->
        (message[:role] || message["role"]) == "assistant"
      end)

    assert [%{"content" => "Single response."}] = assistant_messages
    assert_received {:event, {:assistant, "Single response."}}
  end

  test "tool_finished event compacts large output while model history keeps full content", %{
    session: session
  } do
    path = "tmp/loop_event_large.txt"
    args = %{"filePath" => path, "limit" => 160}
    File.mkdir_p!("tmp")
    File.write!(path, Enum.map_join(1..160, "\n", &("line #{&1} " <> String.duplicate("x", 90))))

    expected_tool_content = Beamcore.Agent.Tools.Read.execute(args)
    parent = self()
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, params ->
      call = Process.get(:mock_completions_calls, 0) + 1
      Process.put(:mock_completions_calls, call)

      case call do
        1 ->
          {:ok,
           %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Reading the file.",
                   "tool_calls" => [tool_call("call_read", "read", args)]
                 }
               }
             ]
           }}

        2 ->
          tool_message =
            Enum.find(params.messages, fn message ->
              (message[:role] || message["role"]) == "tool"
            end)

          send(parent, {:api_tool_content, tool_message[:content] || tool_message["content"]})

          {:ok,
           %{
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Done."}}
             ]
           }}
      end
    end)

    updated =
      Loop.send_message(session, "read a large file", nil, nil,
        silent: true,
        event_handler: fn event -> send(parent, {:event, event}) end
      )

    assert_receive {:event, {:tool_finished, "read", ^args, event_content}}
    assert event_content =~ "[tool output omitted:"
    assert event_content =~ "chars"
    assert event_content =~ "lines"
    assert String.length(event_content) < String.length(expected_tool_content)

    assert_receive {:api_tool_content, ^expected_tool_content}

    tool_message =
      Enum.find(updated.messages, fn message ->
        (message[:role] || message["role"]) == "tool"
      end)

    assert (tool_message[:content] || tool_message["content"]) == expected_tool_content

    File.rm(path)
  end

  test "tool_finished event preserves short output", %{session: session} do
    path = "tmp/loop_event_small.txt"
    args = %{"filePath" => path}
    File.mkdir_p!("tmp")
    File.write!(path, "small output\n")

    expected_tool_content = Beamcore.Agent.Tools.Read.execute(args)
    parent = self()
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:mock_completions_calls, 0) + 1
      Process.put(:mock_completions_calls, call)

      case call do
        1 ->
          {:ok,
           %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Reading the file.",
                   "tool_calls" => [tool_call("call_read", "read", args)]
                 }
               }
             ]
           }}

        2 ->
          {:ok,
           %{
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Done."}}
             ]
           }}
      end
    end)

    Loop.send_message(session, "read a small file", nil, nil,
      silent: true,
      event_handler: fn event -> send(parent, {:event, event}) end
    )

    assert_receive {:event, {:tool_finished, "read", ^args, ^expected_tool_content}}
    refute expected_tool_content =~ "[tool output omitted:"

    File.rm(path)
  end

  test "hard rollover returns the summarized session from the baseline rollover path", %{
    session: session
  } do
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:mock_completions_calls, 0) + 1
      Process.put(:mock_completions_calls, call)

      case call do
        1 ->
          {:ok,
           %{
             "usage" => %{
               "prompt_tokens" => 200_000,
               "completion_tokens" => 10,
               "total_tokens" => 200_010
             },
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Before rollover."}}
             ]
           }}

        2 ->
          {:ok,
           %{
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Compact summary."}}
             ]
           }}
      end
    end)

    updated = Loop.send_message(session, "trigger rollover", nil, nil, silent: true)

    assert updated.compaction_count == session.compaction_count + 1
    refute updated.needs_compaction
    assert updated.last_prompt_tokens == 0
    assert [%{role: "system", content: content}] = updated.messages
    assert content =~ "Compact summary."
  end

  test "freedom mode removes stale policy-blocked history before next API request", %{
    session: session
  } do
    use_temp_policy!(%{version: 1, deny_paths: ["scratch/**"]})
    File.rm_rf!("scratch")

    on_exit(fn ->
      File.rm_rf!("scratch")
    end)

    write_args = %{
      "filePath" => "scratch/yolo_test.ex",
      "content" => "defmodule Scratch.YoloTest do\n  def hello, do: :ok\nend\n"
    }

    stale_messages = [
      %{role: "user", content: "create scratch/yolo_test.ex"},
      %{
        role: "assistant",
        content: "I will try to write it.",
        tool_calls: [tool_call("stale_write", "write", write_args)]
      },
      %{
        role: "tool",
        tool_call_id: "stale_write",
        name: "write",
        content: "Error: Tool call blocked by project policy: scratch/yolo_test.ex is denied."
      },
      %{
        role: "assistant",
        content: "The file is blocked by project policy, so I cannot create it."
      }
    ]

    session = %{
      session
      | messages: session.messages ++ stale_messages,
        project_policy_bypassed?: true,
        policy_override: nil
    }

    parent = self()
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, params ->
      call = Process.get(:mock_completions_calls, 0) + 1
      Process.put(:mock_completions_calls, call)

      if call == 1 do
        combined =
          params.messages
          |> Enum.map_join("\n", &to_string(&1[:content] || &1["content"] || ""))

        send(parent, {:api_messages, params.messages, combined})
      end

      case call do
        1 ->
          {:ok,
           %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Writing file.",
                   "tool_calls" => [tool_call("call_write", "write", write_args)]
                 }
               }
             ]
           }}

        2 ->
          {:ok,
           %{
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Done."}}
             ]
           }}
      end
    end)

    updated =
      Loop.send_message(session, "create scratch/yolo_test.ex", nil, nil,
        silent: true,
        event_handler: fn event -> send(parent, {:event, event}) end
      )

    assert_receive {:api_messages, api_messages, combined}
    refute combined =~ "blocked by project policy"
    refute Enum.any?(api_messages, &is_list(&1[:tool_calls] || &1["tool_calls"]))

    assert File.exists?("scratch/yolo_test.ex")
    assert_receive {:event, {:tool_finished, "write", ^write_args, result}}
    assert result =~ "Successfully wrote"
    assert updated.project_policy_bypassed?
  end

  test "session freedom flag bypasses project policy even without policy_override", %{
    session: session
  } do
    use_temp_policy!(%{version: 1, deny_paths: ["scratch/**"]})
    File.rm_rf!("scratch")

    on_exit(fn ->
      File.rm_rf!("scratch")
    end)

    args = %{
      "filePath" => "scratch/yolo_test.ex",
      "content" => "defmodule Scratch.YoloTest do\n  def hello, do: :ok\nend\n"
    }

    session = %{session | project_policy_bypassed?: true, policy_override: nil}
    parent = self()
    Process.put(:mock_completions_calls, 0)

    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:mock_completions_calls, 0) + 1
      Process.put(:mock_completions_calls, call)

      case call do
        1 ->
          {:ok,
           %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "content" => "Writing file.",
                   "tool_calls" => [tool_call("call_write", "write", args)]
                 }
               }
             ]
           }}

        2 ->
          {:ok,
           %{
             "choices" => [
               %{"message" => %{"role" => "assistant", "content" => "Done."}}
             ]
           }}
      end
    end)

    updated =
      Loop.send_message(session, "create scratch/yolo_test.ex", nil, nil,
        silent: true,
        event_handler: fn event -> send(parent, {:event, event}) end
      )

    assert File.exists?("scratch/yolo_test.ex")
    assert File.read!("scratch/yolo_test.ex") =~ "def hello, do: :ok"
    assert_receive {:event, {:tool_finished, "write", ^args, result}}
    assert result =~ "Successfully wrote"
    assert updated.project_policy_bypassed?
  end

  defp tool_call(id, name, args) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => Jason.encode!(args)
      }
    }
  end

  defp use_temp_policy!(policy) do
    root = Beamcore.Agent.TestPolicyRoot.temp_root("beamcore_loop_policy")
    File.mkdir_p!(Path.join(root, ".beamcore"))
    File.write!(Path.join(root, ".beamcore/policy.json"), Jason.encode!(policy))
    Beamcore.Agent.TestPolicyRoot.setup(root)

    on_exit(fn -> File.rm_rf!(root) end)
  end
end
