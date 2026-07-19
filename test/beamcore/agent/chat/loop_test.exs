defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.{Loop, Session}
  alias Beamcore.Agent.Tools.Dispatcher

  setup do
    Beamcore.Config.put_provider("openai", %{
      api_key: "test-api-key",
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-4o"
    })

    Beamcore.Config.set_active_provider("openai")

    on_exit(fn ->
      Process.delete(:mock_completions_create)
      Process.delete(:loop_completions_calls)
      Process.delete(:loop_events)
    end)
  end

  test "tool specs expose only eeva" do
    specs = Dispatcher.tool_specs()
    assert Enum.map(specs, & &1.function.name) == ["eeva"]
  end

  test "runtime system message is stable across turns" do
    tools = Dispatcher.tool_specs()
    messages = [%{role: "system", content: "stable system"}, %{role: "user", content: "one"}]

    first = Loop.ensure_runtime_message(messages, tools)
    second = Loop.ensure_runtime_message(first ++ [%{role: "assistant", content: "done"}], tools)

    assert Enum.take(second, length(first)) == first
    assert runtime_message_count(first) == 1
    assert runtime_message_count(second) == 1
  end

  test "runtime system message removes legacy duplicates once" do
    tools = Dispatcher.tool_specs()
    runtime = %{role: "system", content: "Exposed tools: old. Previous runtime message."}

    messages = [
      %{role: "system", content: "stable system"},
      runtime,
      runtime,
      %{role: "user", content: "continue"}
    ]

    cleaned = Loop.ensure_runtime_message(messages, tools)

    assert hd(cleaned) == hd(messages)
    assert runtime_message_count(cleaned) == 1
  end

  test "does not force a temperature on provider requests" do
    Process.put(:mock_completions_create, fn _client, params ->
      refute Map.has_key?(params, :temperature)
      assistant_response("provider default used")
    end)

    session = Session.new(Beamcore.Provider.Registry.client())
    result = Loop.send_message(session, "describe the project", self())

    assert List.last(result.messages)["content"] == "provider default used"
  end

  test "rejects an unconfigured session when sending instead of adding a stale warning" do
    Process.put(:mock_completions_create, fn _client, _params ->
      flunk("provider API must not be called for an unknown provider")
    end)

    session =
      Beamcore.Provider.Registry.client()
      |> Session.new()
      |> Session.set_primary_provider("missing-provider", "missing-model")

    result = Loop.send_message(session, "hello", self(), event_handler: &record_event/1)

    assert result == session

    assert Enum.any?(Process.get(:loop_events, []), fn
             {:error, message} -> message =~ "Unknown provider 'missing-provider'"
             _ -> false
           end)
  end

  test "stops only when an identical failure continues after automatic recovery" do
    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:loop_completions_calls, 0) + 1
      Process.put(:loop_completions_calls, call)

      if call > 4 do
        flunk("provider was called after the repeated-failure circuit opened")
      end

      tool_response("call_#{call}", %{"code" => ""})
    end)

    session = Session.new(Beamcore.Provider.Registry.client())
    result = Loop.send_message(session, "run it", self(), event_handler: &record_event/1)

    assert Process.get(:loop_completions_calls) == 4
    assert length(Enum.filter(result.messages, &message_role(&1, "tool"))) == 4

    assert Enum.any?(Process.get(:loop_events, []), fn
             {:error, message} -> message =~ "Automatic recovery could not break"
             _ -> false
           end)
  end

  test "automatic recovery lets the agent change approach without user input" do
    Process.put(:mock_completions_create, fn _client, params ->
      call = Process.get(:loop_completions_calls, 0) + 1
      Process.put(:loop_completions_calls, call)

      case call do
        call when call <= 3 ->
          tool_response("call_#{call}", %{"code" => ""})

        4 ->
          recovery_result =
            params.messages
            |> Enum.reverse()
            |> Enum.find(&message_role(&1, "tool"))
            |> Map.fetch!(:content)
            |> Jason.decode!()

          assert recovery_result["automatic_recovery"]
          assert recovery_result["next_step"] =~ "Continue autonomously"
          tool_response("call_4", %{"code" => "1 + 1"})

        5 ->
          assistant_response("recovered automatically")
      end
    end)

    session = Session.new(Beamcore.Provider.Registry.client())
    result = Loop.send_message(session, "run it", self(), event_handler: &record_event/1)

    assert Process.get(:loop_completions_calls) == 5
    assert List.last(result.messages)["content"] == "recovered automatically"
    assert {:status, :idle} in Process.get(:loop_events, [])

    refute Enum.any?(Process.get(:loop_events, []), fn
             {:error, message} -> message =~ "identical failed"
             _ -> false
           end)
  end

  test "changing failed tool arguments resets the repeated-failure guard" do
    arguments = [%{"code" => ""}, %{"code" => " "}, %{"code" => ""}]

    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:loop_completions_calls, 0) + 1
      Process.put(:loop_completions_calls, call)

      case Enum.at(arguments, call - 1) do
        nil -> assistant_response("recovered")
        args -> tool_response("call_#{call}", args)
      end
    end)

    session = Session.new(Beamcore.Provider.Registry.client())
    result = Loop.send_message(session, "run it", self(), event_handler: &record_event/1)

    assert Process.get(:loop_completions_calls) == 4
    assert List.last(result.messages)["content"] == "recovered"
    assert {:status, :idle} in Process.get(:loop_events, [])
  end

  test "successful tool calls remain unrestricted by the failure guard" do
    Process.put(:mock_completions_create, fn _client, _params ->
      call = Process.get(:loop_completions_calls, 0) + 1
      Process.put(:loop_completions_calls, call)

      if call <= 5 do
        tool_response("call_#{call}", %{"code" => "1 + 1"})
      else
        assistant_response("finished")
      end
    end)

    session = Session.new(Beamcore.Provider.Registry.client())
    result = Loop.send_message(session, "keep working", self())

    assert Process.get(:loop_completions_calls) == 6
    assert List.last(result.messages)["content"] == "finished"
  end

  defp runtime_message_count(messages) do
    Enum.count(messages, fn message ->
      role = message[:role] || message["role"]
      content = message[:content] || message["content"] || ""
      role == "system" and String.starts_with?(content, "Exposed tools:")
    end)
  end

  defp tool_response(id, arguments) do
    {:ok,
     %{
       "choices" => [
         %{
           "message" => %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => id,
                 "type" => "function",
                 "function" => %{"name" => "eeva", "arguments" => Jason.encode!(arguments)}
               }
             ]
           }
         }
       ]
     }}
  end

  defp assistant_response(content) do
    {:ok,
     %{
       "choices" => [
         %{"message" => %{"role" => "assistant", "content" => content}}
       ]
     }}
  end

  defp record_event(event) do
    Process.put(:loop_events, [event | Process.get(:loop_events, [])])
  end

  defp message_role(message, role), do: (message[:role] || message["role"]) == role
end
