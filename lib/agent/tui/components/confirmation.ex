defmodule Beamcore.Agent.TUI.Components.Confirmation do
  @moduledoc false

  alias Beamcore.Agent.TUI.Theme
  alias Beamcore.Agent.TUI.Wrap
  alias ExRatatui.Widgets.Paragraph

  def items(action, width) do
    body = action |> text() |> Wrap.text(width)

    [
      {%Paragraph{text: "Pending plan", style: Theme.style(:running)}, 1},
      {%Paragraph{text: body, style: Theme.style(:panel), wrap: false}, line_count(body) + 1}
    ]
  end

  def text(action) do
    [
      "Summary: #{Map.get(action, :summary, "Planned change")}",
      "Create: #{list(action, :create_files)}",
      "Modify: #{list(action, :modify_files)}",
      "Delete: #{list(action, :delete_files)}",
      "Allowed tools: #{allowed_tools(action)}",
      "Validation: #{blank(Map.get(action, :validation))}",
      "Risks: #{list(action, :risks)}",
      "Use /confirm to execute once or /cancel to clear."
    ]
    |> Enum.join("\n")
  end

  defp list(action, key) do
    action
    |> Map.get(key, [])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp allowed_tools(action) do
    action
    |> get_in([:policy, :allowed_tools])
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "none"
      values -> Enum.join(values, ", ")
    end
  end

  defp blank(value) when value in [nil, ""], do: "none"
  defp blank(value), do: value
  defp line_count(text), do: text |> String.split("\n") |> length()
end
