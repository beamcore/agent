defmodule Beamcore.TUI.WrapTest do
  use ExUnit.Case

  alias Beamcore.TUI.Components.Chat
  alias Beamcore.TUI.Wrap

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

  test "markdown helper preserves snake_case variables and does not strip underscores greedily" do
    text = "The variable `my_snake_case_var` and another `first_var` should not become mangled."
    lines = Wrap.markdown_lines(text, 80)
    joined = Enum.join(lines, "\n")

    assert joined =~ "my_snake_case_var"
    assert joined =~ "first_var"
    refute joined =~ "mysnakecasevar"
  end

  test "markdown helper preserves code block contents and does not normalize them" do
    text = """
    ```elixir
    # This is a comment, not a heading
    - This is a bullet, not a list
    | This | is not a table row |
    `backticks` and _underscores_ and **asterisks**
    ```
    """

    lines = Wrap.markdown_lines(text, 80)
    joined = Enum.join(lines, "\n")

    # In Wrap.markdown_lines/2:
    # 1. The code block fence lines themselves (```elixir and ```) are dropped by drop_fence_lines/3.
    # 2. But the content inside the code block should be preserved EXACTLY as is, without normalization!
    assert joined =~ "# This is a comment, not a heading"
    assert joined =~ "- This is a bullet, not a list"
    assert joined =~ "| This | is not a table row |"
    assert joined =~ "`backticks` and _underscores_ and **asterisks**"
  end
end
