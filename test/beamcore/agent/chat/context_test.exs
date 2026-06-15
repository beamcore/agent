defmodule Beamcore.Agent.Chat.ContextTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.{Context, ToolRuntime}

  test "ignores non-eeva historical tool names" do
    context = Context.new()
    assert Context.update_from_tool(context, "modify_file", %{"path" => "x"}, "ok") == context
  end

  test "user request keeps autonomous eeva constraints" do
    context =
      Context.new() |> Context.from_user_request("fix it", ToolRuntime.default())

    summary = Context.summary(context)
    assert summary =~ "All executable work goes through Eeva"
    assert summary =~ "fix it"
  end

  test "records compact eeva caps failures" do
    result = Jason.encode!(%{"ok" => false, "summary" => "Eeva execution is blocked by guard."})

    context =
      Context.new()
      |> Context.update_from_tool("eeva", %{"code" => "File.write!(\"a\", \"b\")"}, result)

    assert Context.summary(context) =~ "Blocked attempts"
  end
end
