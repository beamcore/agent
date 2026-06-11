defmodule Beamcore.Agent.Chat.ContextTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.{Context, ToolPolicy}

  test "tracks workspace mutations reported by eeva" do
    result =
      Jason.encode!(%{
        "ok" => true,
        "filesystem_changes" => %{
          "mutations" => [
            %{"path" => "lib/a.ex"},
            %{"path" => "lib/b.ex", "target_path" => "lib/c.ex"}
          ]
        }
      })

    context = Context.new(:elixir, :mix) |> Context.update_from_tool("eeva", %{}, result)

    assert "lib/a.ex" in context.modified_files
    assert "lib/b.ex" in context.modified_files
    assert "lib/c.ex" in context.modified_files
  end

  test "ignores non-eeva historical tool names" do
    context = Context.new(:elixir, :mix)
    assert Context.update_from_tool(context, "modify_file", %{"path" => "x"}, "ok") == context
  end

  test "user request keeps autonomous eeva constraints" do
    context =
      Context.new(:elixir, :mix) |> Context.from_user_request("fix it", ToolPolicy.default())

    summary = Context.summary(context)
    assert summary =~ "All executable work goes through Eeva"
    assert summary =~ "fix it"
  end

  test "records compact eeva policy failures" do
    result = Jason.encode!(%{"ok" => false, "summary" => "Eeva execution is blocked by policy."})

    context =
      Context.new(:elixir, :mix)
      |> Context.update_from_tool("eeva", %{"code" => "File.write!(\"a\", \"b\")"}, result)

    assert Context.summary(context) =~ "Blocked attempts"
  end
end
