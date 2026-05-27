defmodule Beamcore.TUI.Components.EmptyState do
  @moduledoc false

  alias Beamcore.TUI.{State, Theme}
  alias ExRatatui.Widgets.Paragraph
  alias Number.SI

  def widget(text) when is_binary(text) do
    %Paragraph{
      text: String.trim(text),
      style: Theme.style(:system),
      alignment: :center,
      wrap: false
    }
  end

  def text(state) do
    usage = State.usage(state.session)
    session_id = if state.session, do: state.session.session_id, else: "starting"
    model = State.model(state.session)

    {org, repo} = Beamcore.Memory.detect_org_repo()

    total =
      [:repo_map, :patterns, :decisions, :errors, :context]
      |> Enum.map(fn type -> length(Beamcore.Memory.list(org, repo, type)) end)
      |> Enum.sum()

    """
    BEAMCORE.AGENT
    Fast, visible coding workflow for this workspace

    Quick starts
      Review project        Generate diagram
      Explain a module      Make a focused change

    /help commands    Tab activity details    autonomous tools
    Tool calls, plans, and policy blocks appear in Activity.

    Available #{total} memories

    #{model} · #{State.provider()} · session #{session_id} · tok #{SI.number_to_si(usage.last_prompt_tokens || 0, precision: 1, trim: true)}/#{SI.number_to_si(usage.total_tokens || 0, precision: 1, trim: true)}
    """
  end
end
