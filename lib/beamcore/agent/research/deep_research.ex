defmodule Beamcore.Agent.Research.DeepResearch do
  @moduledoc """
  Minimal local-friendly Deep Research workflow.

  The workflow is intentionally small:

  1. understand the request,
  2. keep a compact plan,
  3. gather from available bounded context/tools,
  4. compress intermediate findings,
  5. produce a final answer.

  This module prepares bounded model context; it does not add new tools or a
  multi-agent scheduler.
  """

  alias Beamcore.Agent.Chat.Budget

  @index_limit 3_000
  @artifact_limit 2_000

  def prepare_messages(messages, session, budget) when is_list(messages) do
    harness = harness_message(session, budget)

    messages
    |> inject_harness(harness)
    |> Budget.fit_messages(budget)
  end

  def record_researcher_stage(session, summary \\ "Researcher prepared bounded context.") do
    Beamcore.Agent.Chat.Session.append_timeline(session, :research_stage, summary,
      role: :researcher,
      title: "Researcher stage",
      reversible: true
    )
  end

  def record_synthesizer_stage(session, summary \\ "Synthesizer reviewed bounded context.") do
    Beamcore.Agent.Chat.Session.append_timeline(session, :research_stage, summary,
      role: :synthesizer,
      title: "Synthesizer stage",
      reversible: true
    )
  end

  def harness_message(session, budget) do
    topic = main_topic(session)
    artifacts = artifacts(session.workspace_root)
    index = research_index(session.workspace_root)

    %{
      role: "system",
      content:
        Beamcore.Agent.Core.Prompts.deep_research_harness(
          topic,
          artifacts,
          index,
          budget
        )
    }
  end

  def compress_findings(text, budget) when is_binary(text) do
    Budget.compact_text(text, max(budget * 4, 1))
  end

  defp inject_harness([system, context | rest], harness)
       when is_map(system) and is_map(context) do
    role1 = system[:role] || system["role"]
    role2 = context[:role] || context["role"]
    content2 = context[:content] || context["content"] || ""

    if role1 == "system" and role2 == "system" and
         String.starts_with?(content2, "Known session context:") do
      [system, context, harness | rest]
    else
      [system, harness, context | rest]
    end
  end

  defp inject_harness([system | rest], harness) when is_map(system), do: [system, harness | rest]
  defp inject_harness(messages, harness), do: [harness | messages]

  defp main_topic(session) do
    in_memory =
      Enum.find_value(session.messages || [], fn msg ->
        role = msg[:role] || msg["role"]
        content = msg[:content] || msg["content"]

        if role in [:user, "user"] and is_binary(content) and String.trim(content) != "" do
          String.trim(content)
        end
      end)

    in_memory || first_user_from_log(session.log_file) || "Unknown research topic"
  end

  defp first_user_from_log(nil), do: nil

  defp first_user_from_log(log_file) do
    if File.exists?(log_file) do
      log_file
      |> File.stream!()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"role" => "user", "content" => content}} when is_binary(content) ->
            String.trim(content)

          _ ->
            nil
        end
      end)
    end
  end

  defp artifacts(nil), do: "(No research directory)"

  defp artifacts(workspace_root) do
    if File.dir?(workspace_root) do
      workspace_root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.map(fn abs_path ->
        rel_path = Path.relative_to(abs_path, workspace_root)

        size =
          case File.stat(abs_path) do
            {:ok, %File.Stat{size: size}} -> size
            _ -> 0
          end

        {rel_path, size}
      end)
      |> Enum.reject(fn {rel_path, _size} -> rel_path == "research_index.md" end)
      |> Enum.map(fn {rel_path, size} -> "- #{rel_path} (#{size} bytes)" end)
      |> Enum.join("\n")
      |> blank_to_no_artifacts()
      |> Budget.compact_text(@artifact_limit)
    else
      "(No research directory)"
    end
  end

  defp research_index(nil), do: "(No research index)"

  defp research_index(workspace_root) do
    index_file = Path.join(workspace_root, "research_index.md")

    if File.exists?(index_file) do
      case File.read(index_file) do
        {:ok, content} -> content |> String.trim() |> Budget.compact_text(@index_limit)
        _ -> "(Unable to read research_index.md)"
      end
    else
      "(research_index.md does not exist yet)"
    end
  end

  defp blank_to_no_artifacts(""), do: "(No research artifacts created yet)"
  defp blank_to_no_artifacts(value), do: value
end
