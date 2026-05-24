defmodule Beamcore.Agent.TUI.WrapTest do
  use ExUnit.Case

  alias Beamcore.Agent.TUI.Components.Chat
  alias Beamcore.Agent.TUI.Wrap

  test "long assistant text wraps into multiple lines within width" do
    text =
      "I'll help you generate a PNG diagram of your Elixir code. First, I will inspect the project structure and identify the main modules."

    lines = Wrap.lines(text, 42)

    assert length(lines) > 2
    assert Enum.all?(lines, &(String.length(&1) <= 42))
  end

  test "long user text wraps into multiple lines within width" do
    text =
      "generate png diagram of my code into the generated directory and include the most important modules"

    lines = Wrap.lines(text, 34)

    assert length(lines) > 2
    assert Enum.all?(lines, &(String.length(&1) <= 34))
  end

  test "role labels are preserved separately from wrapped body" do
    lines =
      Chat.render_message_lines("Agent", "This is a long assistant response that must wrap.", 20)

    assert hd(lines) == "Agent"
    assert length(lines) > 2
    assert Enum.all?(tl(lines), &(String.length(&1) <= 20))
  end

  test "narrow width still produces readable output" do
    lines = Wrap.lines("small terminals should still show readable prose", 12)

    assert length(lines) >= 4
    assert Enum.all?(lines, &(String.length(&1) <= 12))
  end

  test "long unbroken token is split safely" do
    [first | _rest] = lines = Wrap.lines("prefix " <> String.duplicate("x", 90), 18)

    assert first == "prefix"
    assert Enum.all?(lines, &(String.length(&1) <= 18))
  end

  test "code block lines do not crash and are bounded" do
    text = """
    ```elixir
    #{String.duplicate("very_long_code_token_", 10)}
    ```
    """

    lines = Wrap.lines(text, 30)

    assert Enum.any?(lines, &String.starts_with?(&1, "```"))
    assert Enum.all?(lines, &(String.length(&1) <= 30))
  end

  test "markdown helper removes raw emphasis markers for height estimation" do
    text = """
    ### **Common Elixir Tasks**
    | Task | Action |
    |------|--------|
    | Create module | `lib/foo.ex` |
    """

    lines = Wrap.markdown_lines(text, 36)
    joined = Enum.join(lines, "\n")

    refute joined =~ "**"
    refute joined =~ "|------"
    assert joined =~ "Common Elixir Tasks"
    assert joined =~ "Task · Action"
    assert Enum.all?(lines, &(String.length(&1) <= 36))
  end
end
