defmodule Beamcore.Agent.Chat.LoopTest do
  use ExUnit.Case
  alias Beamcore.Agent.Chat.{Loop, MultilineInput}

  test "Loop.start/2 function signature is correct" do
    assert is_function(&Loop.start/2, 2)
  end

  test "multiline input collects lines until /end" do
    assert {:ok, text, []} =
             MultilineInput.collect_until(
               ["Small task", "Create scratch/a.ex", "/end"],
               "/end"
             )

    assert text == "Small task\nCreate scratch/a.ex"
  end

  test "multiline input treats slash commands inside paste as text" do
    assert {:ok, text, []} =
             MultilineInput.collect_until(
               ["Please include this literal command:", "/new", "/end"],
               "/end"
             )

    assert text == "Please include this literal command:\n/new"
  end

  test "multiline input rejects empty paste" do
    assert {:error, :empty, []} = MultilineInput.collect_until(["", "   ", "/end"], "/end")
  end

  test "multiline input supports heredoc terminator" do
    assert {:ok, text, []} = MultilineInput.collect_until(["line 1", "line 2", ">>>"], ">>>")

    assert text == "line 1\nline 2"
  end
end
