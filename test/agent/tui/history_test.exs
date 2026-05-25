defmodule Beamcore.Agent.TUI.HistoryTest do
  use ExUnit.Case, async: false

  alias Beamcore.Agent.TUI.History

  setup do
    # Generate a unique temp history path for this test inside the workspace
    # (since we shouldn't write outside the workspace/tmp dirs, we can write in a local scratch or system tmp)
    temp_dir = System.tmp_dir!()
    unique_id = :erlang.unique_integer([:positive])
    temp_path = Path.join(temp_dir, "history_test_#{unique_id}.json")

    # Set the history path config
    Application.put_env(:agent, :history_path, temp_path)

    # Cleanup after test
    on_exit(fn ->
      File.rm(temp_path)
      Application.delete_env(:agent, :history_path)
    end)

    %{path: temp_path}
  end

  test "returns empty list when file does not exist" do
    assert History.load() == []
  end

  test "appends and loads history entries", %{path: path} do
    History.append("hello")
    History.append("world")

    assert History.load() == ["hello", "world"]
    assert File.exists?(path)
  end

  test "skips adjacent duplicate entries" do
    History.append("hello")
    History.append("hello")
    History.append("world")
    History.append("hello")

    assert History.load() == ["hello", "world", "hello"]
  end

  test "handles multi-line entries correctly" do
    multi_line = "hello\nworld\nthis\nis\na\ntest"
    History.append(multi_line)
    History.append("single line")

    assert History.load() == [multi_line, "single line"]
  end

  test "handles unicode and special characters" do
    unicode_str = "🚀 BeamCore Elixir TUI! 💻 \\n \\\\ \"quote\""
    History.append(unicode_str)

    assert History.load() == [unicode_str]
  end
end
