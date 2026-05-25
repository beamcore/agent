defmodule Beamcore.Agent.Chat.CommandsTest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  alias Beamcore.Agent.Chat.{Commands, Context, Session, ToolPolicy}

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

  test "/help does not present confirm as the normal workflow" do
    session = Beamcore.Agent.OpenAI.client() |> Session.new()

    output = capture_io(fn -> assert Commands.execute("help", session) == session end)

    refute output =~ "/confirm"
    refute output =~ "pending plan"
    assert output =~ "/policy"
    assert output =~ "/yolo"
  end

  test "/cancel clears legacy pending action" do
    pending_action = pending_action()

    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.put(:pending_user_message, "Create scratch/policy_test.ex")
      |> Map.update!(:context, &Context.put_pending_action(&1, pending_action))

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

  test "/confirm keeps legacy pending policy compatibility" do
    pending_action = pending_action()

    session =
      Beamcore.Agent.OpenAI.client()
      |> Session.new()
      |> Map.put(:pending_user_message, "Create scratch/policy_test.ex")
      |> Map.update!(:context, &Context.put_pending_action(&1, pending_action))

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

  defp pending_action do
    policy = ToolPolicy.restricted_write_policy(["scratch/policy_test.ex"], ["write"])

    %{
      summary: "Create a scratch module",
      create_files: ["scratch/policy_test.ex"],
      modify_files: [],
      delete_files: [],
      allowed_tools: ["write"],
      validation: "",
      risks: [],
      allowed_write_paths: ["scratch/policy_test.ex"],
      policy: policy
    }
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

  test "unknown command keeps plain CLI error rendering" do
    session = Beamcore.Agent.OpenAI.client() |> Session.new()

    output = capture_io(fn -> assert Commands.execute("missing", session) == session end)

    assert output =~ "Unknown command: /missing"
  end

  test "unknown command can be captured by TUI output callback" do
    session = Beamcore.Agent.OpenAI.client() |> Session.new()

    assert Commands.execute("missing", session, output: fn message -> send(self(), message) end) ==
             session

    assert_received "Error: Unknown command: /missing"
  end

  test "/policy shows summary and initializes config" do
    with_tmp_cwd(fn ->
      session = Beamcore.Agent.OpenAI.client() |> Session.new()

      output = capture_io(fn -> assert Commands.execute("policy", session) == session end)
      assert output =~ "Project policy: not loaded"

      init_output =
        capture_io(fn -> assert Commands.execute("policy init", session) == session end)

      assert init_output =~ "Project policy initialized"
      assert File.exists?(".beamcore/policy.json")

      show_output =
        capture_io(fn -> assert Commands.execute("policy show", session) == session end)

      assert show_output =~ "\"deny_paths\""
    end)
  end

  test "/policy updates strict settings immediately" do
    with_tmp_cwd(fn ->
      session = Beamcore.Agent.OpenAI.client() |> Session.new()

      output =
        capture_io(fn ->
          assert Commands.execute("policy deny path secrets/**", session) == session
          assert Commands.execute("policy tool web_get deny", session) == session
        end)

      decoded = Jason.decode!(File.read!(".beamcore/policy.json"))

      assert output =~ "policy deny secrets/**"
      assert output =~ "policy tool web_get deny"
      assert "secrets/**" in decoded["deny_paths"]
      assert decoded["tool_permissions"]["web_get"] == "deny"
    end)
  end

  test "/policy weaker changes require --confirm" do
    with_tmp_cwd(fn ->
      session = Beamcore.Agent.OpenAI.client() |> Session.new()

      capture_io(fn ->
        Commands.execute("policy deny path secrets/**", session)
        Commands.execute("policy tool web_get deny", session)
      end)

      blocked =
        capture_io(fn ->
          assert Commands.execute("policy remove deny path secrets/**", session) == session
          assert Commands.execute("policy tool web_get allow", session) == session
        end)

      assert blocked =~ "weakens project policy"

      allowed =
        capture_io(fn ->
          assert Commands.execute("policy remove deny path secrets/** --confirm", session) ==
                   session

          assert Commands.execute("policy tool web_get allow --confirm", session) == session
        end)

      decoded = Jason.decode!(File.read!(".beamcore/policy.json"))

      assert allowed =~ "Project policy updated"
      refute "secrets/**" in decoded["deny_paths"]
      assert decoded["tool_permissions"]["web_get"] == "allow"
    end)
  end

  test "/policy reset requires --confirm and malformed commands are helpful" do
    with_tmp_cwd(fn ->
      session = Beamcore.Agent.OpenAI.client() |> Session.new()

      capture_io(fn -> Commands.execute("policy deny path secrets/**", session) end)
      assert File.exists?(".beamcore/policy.json")

      output =
        capture_io(fn ->
          assert Commands.execute("policy reset", session) == session
          assert Commands.execute("policy banana", session) == session
        end)

      assert output =~ "weakens policy"
      assert output =~ "Malformed /policy command"
      assert File.exists?(".beamcore/policy.json")

      reset =
        capture_io(fn ->
          assert Commands.execute("policy reset --confirm", session) == session
        end)

      assert reset =~ "Project policy reset"
      refute File.exists?(".beamcore/policy.json")
    end)
  end

  defp with_tmp_cwd(fun) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "beamcore_policy_command_#{System.unique_integer([:positive])}"
      )

    previous = File.cwd!()
    File.mkdir_p!(tmp)
    File.cd!(tmp)

    try do
      fun.()
    after
      File.cd!(previous)
      File.rm_rf!(tmp)
    end
  end
end
