defmodule Beamcore.Agent.Research.DeepResearchTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Research.DeepResearch

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "beamcore_deep_research_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    session = %Session{
      messages: [
        %{role: "system", content: "System"},
        %{role: "user", content: "Research local Elixir agent architecture"}
      ],
      session_id: "research-test",
      log_file: Path.join(tmp_dir, "session.json"),
      workspace_root: tmp_dir,
      screen_type: :research,
      context: Beamcore.Agent.Chat.Context.new(:unknown, :unknown)
    }

    %{session: session, tmp_dir: tmp_dir}
  end

  test "injects bounded deep research workflow context", %{session: session, tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "research_index.md"), String.duplicate("index ", 2_000))
    File.write!(Path.join(tmp_dir, "notes.md"), String.duplicate("notes ", 2_000))

    messages = DeepResearch.prepare_messages(session.messages, session, 900)
    harness = Enum.find(messages, &String.contains?(&1.content || "", "[DEEP RESEARCH WORKFLOW]"))

    assert harness
    assert harness.content =~ "Research local Elixir agent architecture"
    assert harness.content =~ "notes.md"
    assert Beamcore.Agent.Chat.Budget.estimate_tokens(messages) <= 900
  end

  test "compresses findings deterministically" do
    text = "begin " <> String.duplicate("middle ", 1_000) <> "end"

    compressed = DeepResearch.compress_findings(text, 100)

    assert String.starts_with?(compressed, "begin")
    assert String.ends_with?(compressed, "end")
    assert String.length(compressed) <= 400
  end

  test "records researcher and synthesizer roles in the timeline", %{session: session} do
    session =
      session
      |> Map.put(:state_file, nil)
      |> Map.put(:checkpoint_file, nil)
      |> Map.put(:timeline, [])
      |> Map.put(:checkpoints, [])
      |> Map.put(:branches, Beamcore.Agent.Timeline.initial_branches())
      |> Map.put(:branch_id, Beamcore.Agent.Timeline.initial_branch_id())
      |> DeepResearch.record_researcher_stage("Created research plan.")
      |> DeepResearch.record_synthesizer_stage("Reviewed findings.")

    assert Enum.any?(session.timeline, &(&1.role == :researcher and &1.type == :research_stage))
    assert Enum.any?(session.timeline, &(&1.role == :synthesizer and &1.type == :research_stage))
  end
end
