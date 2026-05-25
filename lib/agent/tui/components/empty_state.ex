defmodule Beamcore.Agent.TUI.Components.EmptyState do
  @moduledoc false

  alias Beamcore.Agent.TUI.Components.Mascot
  alias Beamcore.Agent.TUI.{State, Theme}
  alias ExRatatui.Widgets.Paragraph

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

    """
    #{Mascot.portrait(state.status, state.spinner_step, state.unicode?)}

    BEAMCORE.AGENT
    Fast, visible coding workflow for this workspace.

    ╭─ Quick starts ─────────────────────────╮
    │  Review project      Plan safe change  │
    │  Generate diagram    Explain a module  │
    ╰────────────────────────────────────────╯

    /help commands    Tab activity details    autonomous tools
    Tool calls, plans, and policy blocks appear in Activity.

    #{model} · #{State.provider()} · session #{session_id} · tok #{usage.last_prompt_tokens}/#{usage.total_tokens}
    """
  end
end
