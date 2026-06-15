defmodule Beamcore.Agent.Discovery.WorkspaceContextTest do
  use ExUnit.Case
  alias Beamcore.Agent.Discovery.WorkspaceContext

  setup do
    test_dir =
      Path.join(
        System.tmp_dir!(),
        "beamcore_workspace_ctx_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    {:ok, test_dir: test_dir}
  end

  describe "load/1" do
    test "returns empty list when no instruction files exist", %{test_dir: test_dir} do
      assert WorkspaceContext.load(test_dir) == []
    end

    test "loads AGENTS.md when present", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "AGENTS.md"), "# Project rules\nDo X then Y.")

      result = WorkspaceContext.load(test_dir)
      assert [{"AGENTS.md", "# Project rules\nDo X then Y."}] = result
    end

    test "loads CLAUDE.md when present", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "CLAUDE.md"), "# Claude instructions\nBe concise.")

      result = WorkspaceContext.load(test_dir)
      assert [{"CLAUDE.md", "# Claude instructions\nBe concise."}] = result
    end

    test "loads .cursorrules when present", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, ".cursorrules"), "Use tabs not spaces.")

      result = WorkspaceContext.load(test_dir)
      assert [{".cursorrules", "Use tabs not spaces."}] = result
    end

    test "loads COPILOT.md when present", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "COPILOT.md"), "# Copilot guide\nFollow PEP8.")

      result = WorkspaceContext.load(test_dir)
      assert [{"COPILOT.md", "# Copilot guide\nFollow PEP8."}] = result
    end

    test "loads multiple files in defined order", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "AGENTS.md"), "agents content")
      File.write!(Path.join(test_dir, "CLAUDE.md"), "claude content")
      File.write!(Path.join(test_dir, ".cursorrules"), "cursor content")
      File.write!(Path.join(test_dir, "COPILOT.md"), "copilot content")

      result = WorkspaceContext.load(test_dir)
      assert length(result) == 4

      filenames = Enum.map(result, &elem(&1, 0))
      assert filenames == ["AGENTS.md", "CLAUDE.md", ".cursorrules", "COPILOT.md"]
    end

    test "skips files that are empty after trimming", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "AGENTS.md"), "   \n  ")
      File.write!(Path.join(test_dir, "CLAUDE.md"), "real content")

      result = WorkspaceContext.load(test_dir)
      assert [{"CLAUDE.md", "real content"}] = result
    end

    test "trims whitespace from file contents", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "AGENTS.md"), "\n\n  some rules  \n\n")

      result = WorkspaceContext.load(test_dir)
      assert [{"AGENTS.md", "some rules"}] = result
    end

    test "skips non-existent files silently", %{test_dir: test_dir} do
      File.write!(Path.join(test_dir, "CLAUDE.md"), "only claude")

      result = WorkspaceContext.load(test_dir)
      assert [{"CLAUDE.md", "only claude"}] = result
    end
  end

  describe "instruction_files/0" do
    test "returns the list of well-known filenames" do
      files = WorkspaceContext.instruction_files()
      assert "AGENTS.md" in files
      assert "CLAUDE.md" in files
      assert ".cursorrules" in files
      assert "COPILOT.md" in files
    end
  end
end
