defmodule Beamcore.Agent.Chat.CommandsTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Beamcore.Agent.Chat.{Commands, Context, Session}

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })
  end

  test "/new resets session context" do
    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.update!(:context, fn context ->
        Context.update_from_tool(context, "read", %{"filePath" => "README.md"}, "content")
      end)

    assert "README.md" in session.context.inspected_files

    new_session =
      capture_io(fn ->
        result = Commands.execute("new", session)
        send(self(), {:new_session, result})
      end)

    assert new_session =~ "Starting new session"
    assert_receive {:new_session, result}
    assert MapSet.size(result.context.inspected_files) == 0
  end

  test "/context prints compact context summary" do
    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.update!(:context, fn context ->
        Context.update_from_tool(context, "read", %{"filePath" => "mix.exs"}, "content")
      end)

    output = capture_io(fn -> assert Commands.execute("context", session) == session end)

    assert output =~ "Known session context"
    assert output =~ "mix.exs"
  end

  test "/context clear clears context without replacing the session" do
    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.update!(:context, fn context ->
        Context.update_from_tool(context, "read", %{"filePath" => "mix.exs"}, "content")
      end)

    cleared =
      capture_io(fn ->
        result = Commands.execute("context clear", session)
        send(self(), {:cleared_session, result})
      end)

    assert cleared =~ "Session context cleared."
    assert_receive {:cleared_session, result}
    assert result.session_id == session.session_id
    assert MapSet.size(result.context.inspected_files) == 0
  end

  test "/confirm reports when there is no pending action" do
    session = Beamcore.Agent.OpenAI.client() |> Session.new()

    output = capture_io(fn -> assert Commands.execute("confirm", session) == session end)

    assert output =~ "No pending action to confirm."
  end

  test "/cancel clears pending action" do
    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.put(:pending_user_message, "Create scratch/policy_test.ex")
      |> Map.update!(:context, fn context ->
        result =
          Beamcore.Agent.Tools.Plan.execute(%{
            "summary" => "Create a scratch module",
            "create_files" => ["scratch/policy_test.ex"],
            "allowed_tools" => ["write"]
          })

        Context.update_from_tool(context, "plan", %{}, result)
      end)

    output =
      capture_io(fn ->
        result = Commands.execute("cancel", session)
        send(self(), {:canceled, result})
      end)

    assert output =~ "Pending action canceled."
    assert_receive {:canceled, result}
    assert result.pending_user_message == nil
    assert result.context.pending_action == nil
  end

  test "/confirm activates pending policy for one turn" do
    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.put(:pending_user_message, "Create scratch/policy_test.ex")
      |> Map.update!(:context, fn context ->
        result =
          Beamcore.Agent.Tools.Plan.execute(%{
            "summary" => "Create a scratch module",
            "create_files" => ["scratch/policy_test.ex"],
            "allowed_tools" => ["write"]
          })

        Context.update_from_tool(context, "plan", %{}, result)
      end)

    output =
      capture_io(fn ->
        result = Commands.execute("confirm", session)
        send(self(), {:confirmed, result})
      end)

    assert output =~ "Confirmed pending action."

    assert_receive {:confirmed, {:run_pending, confirmed_session, message, policy}}
    assert confirmed_session.session_id == session.session_id
    assert message =~ "Confirmed execution request."
    assert message =~ "The user confirmed the pending plan."
    assert message =~ "Do not call the plan tool."
    assert message =~ "Do not ask for confirmation again."
    assert message =~ "Policy:"
    assert message =~ "mode: restricted_write"
    assert message =~ "allowed_write_paths:"
    assert message =~ "- scratch/policy_test.ex"
    assert message =~ "allowed_tools:"
    assert message =~ "- write"
    assert message =~ "blocked_tools:"
    assert message =~ "- task"
    assert message =~ "Original user request:"
    assert message =~ "Create scratch/policy_test.ex"

    assert :ok ==
             Beamcore.Agent.Chat.ToolPolicy.allow_tool_call(policy, "write", %{
               "filePath" => "scratch/policy_test.ex"
             })

    cleared = Session.clear_pending_action(confirmed_session)
    assert cleared.pending_user_message == nil
    assert cleared.context.pending_action == nil
  end

  test "/yolo sets policy override to unrestricted" do
    session = Beamcore.Agent.OpenAI.client() |> Session.new()

    output =
      capture_io(fn ->
        result = Commands.execute("yolo", session)
        send(self(), {:yolo, result})
      end)

    assert output =~ "YOLO mode enabled"
    assert_receive {:yolo, result}
    assert result.policy_override != nil
    assert result.policy_override.mode == :unrestricted
  end
end
