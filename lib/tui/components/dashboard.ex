defmodule Beamcore.TUI.Components.Dashboard do
  @moduledoc """
  The Dashboard (F2) body: a stack of native-bordered panels.

  Replaces the former hand-drawn System page. Each panel is a native
  `Block` (rounded border + title) wrapping its content. Wide terminals
  show a two-column top row (Token Usage, Providers) above a full-width
  Activity feed and a full-width Mesh canvas; narrow terminals collapse to
  a single column. The permanently one-line Eeva runtime status rides a
  borderless row above the status bar rather than owning a panel.

  Panels whose content can outgrow their box — the add-provider form and
  the Activity feed — window to the panel height and draw a right-edge
  `Scrollbar` for the overflow. The Mesh canvas is bounds-based, so it
  re-fits to any panel size instead of scrolling. Panel content is fed
  entirely from data the dashboard state already owns — token stats, the
  provider store, the mesh snapshot, and the Eeva runtime status.
  """

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Attach, Mesh, Stats}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Layout, as: RatLayout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Scrollbar, Table}
  alias ExRatatui.Widgets.Block.Title

  @narrow_width 88

  @doc """
  Builds the dashboard panel grid for `area`.

  Returns a list of `{widget, %Rect{}}` tuples — one per panel — laid out
  within `area`.
  """
  @spec panels(struct(), Rect.t()) :: [{struct(), Rect.t()}]
  def panels(system, %Rect{width: width} = area) when width < @narrow_width do
    [usage, providers, activity, mesh, eeva] =
      RatLayout.split(area, :vertical, [
        {:percentage, 24},
        {:percentage, 24},
        {:fill, 1},
        {:percentage, 24},
        {:length, 1}
      ])

    build(system, usage, providers, activity, mesh, eeva)
  end

  def panels(system, %Rect{} = area) do
    # Activity grows into the space reclaimed from the one-line Eeva strip;
    # Mesh spans the full width and re-fits its canvas to whatever it is given.
    [top, activity, mesh, eeva] =
      RatLayout.split(area, :vertical, [
        {:percentage, 34},
        {:fill, 1},
        {:percentage, 30},
        {:length, 1}
      ])

    [usage, providers] =
      RatLayout.split(top, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    build(system, usage, providers, activity, mesh, eeva)
  end

  defp build(system, usage_rect, providers_rect, activity_rect, mesh_rect, eeva_rect) do
    [{usage_panel(system, usage_rect), usage_rect}] ++
      providers_widgets(system, providers_rect) ++
      activity_widgets(system, activity_rect) ++
      [{mesh_panel(system, mesh_rect), mesh_rect}] ++
      eeva_widgets(eeva_rect)
  end

  defp usage_panel(system, _rect) do
    stats = system.stats_snapshot || %{}
    block = panel_block("Token Usage", [])

    if map_size(stats) == 0 do
      %Paragraph{
        text: [
          %Line{spans: [%Span{content: "no usage recorded yet", style: Theme.style(:muted)}]}
        ],
        style: Theme.style(:base),
        wrap: false,
        block: block
      }
    else
      %{Stats.bar_chart(stats) | block: block}
    end
  end

  # The add-provider form is taller than the panel, so it scrolls the focused
  # field into view and shows a right-edge scrollbar for the overflow.
  defp providers_widgets(system, rect) do
    p = system.providers
    inner_h = max(rect.height - 2, 1)
    panel = {providers_panel(system, inner_h), rect}

    if p.adding? do
      %{position: pos, content_length: total} = Providers.form_scroll_state(p, inner_h)
      [panel | scrollbar_widgets(rect, pos, total, inner_h)]
    else
      [panel]
    end
  end

  defp providers_panel(system, inner_h) do
    p = system.providers

    if p.adding? do
      %Paragraph{
        text: Providers.form_lines(p, inner_h),
        style: Theme.style(:base),
        wrap: false,
        block: panel_block("Providers", [])
      }
    else
      %{Providers.table(p) | block: panel_block("Providers", [providers_hint()])}
    end
  end

  defp providers_hint do
    %Title{
      content: " enter activate · a add · d delete ",
      position: :bottom,
      alignment: :right,
      style: Theme.style(:muted)
    }
  end

  # Activity is newest-first, so the latest rows are always shown; older ones
  # spill past the fold and a right-edge scrollbar marks how much is hidden.
  defp activity_widgets(system, rect) do
    inner_h = max(rect.height - 2, 1)
    visible = max(inner_h - 1, 1)
    panel = {activity_panel(system, visible), rect}
    total = length(system.activity)

    [panel | scrollbar_widgets(rect, 0, total, visible)]
  end

  defp activity_panel(system, visible) do
    block = panel_block("Activity", [live_caption()])

    case system.activity do
      [] ->
        %Paragraph{
          text: [%Line{spans: [%Span{content: "no activity yet", style: Theme.style(:muted)}]}],
          style: Theme.style(:base),
          wrap: false,
          block: block
        }

      activity ->
        %{activity_table(activity, visible) | block: block}
    end
  end

  defp live_caption do
    %Title{content: " live ", position: :bottom, alignment: :right, style: Theme.style(:accent)}
  end

  defp activity_table(activity, visible) do
    %Table{
      header: activity_header(),
      rows: activity |> Enum.take(visible) |> Enum.map(&activity_row/1),
      widths: [{:length, 8}, {:length, 14}, {:min, 0}, {:length, 10}],
      column_spacing: 1,
      style: Theme.style(:base)
    }
  end

  defp activity_header do
    muted = Theme.style(:muted)

    for label <- ["time", "kind", "detail", "result"] do
      %Span{content: label, style: muted}
    end
  end

  defp activity_row(event) do
    [
      %Span{content: fmt_time(event.timestamp_ms), style: Theme.style(:subtle)},
      %Span{content: truncate(event.name, 14), style: Theme.style(:muted)},
      %Span{content: truncate(activity_detail(event), 60), style: Theme.style(:base)},
      status_cell(event.status)
    ]
  end

  defp activity_detail(%{summary: summary}) when is_binary(summary) and summary != "", do: summary
  defp activity_detail(%{label: label}) when is_binary(label), do: label
  defp activity_detail(_event), do: ""

  defp status_cell(status) do
    {glyph, style} = status_display(status)
    %Span{content: "#{glyph} #{status}", style: style}
  end

  defp status_display(status) when status in [:done, :completed], do: {"✓", Theme.style(:done)}
  defp status_display(status) when status in [:error, :blocked], do: {"✗", Theme.style(:error)}
  defp status_display(:running), do: {"◐", Theme.style(:running)}
  defp status_display(:queued), do: {"·", Theme.style(:queued)}
  defp status_display(_status), do: {"·", Theme.style(:muted)}

  defp fmt_time(ms) when is_integer(ms) do
    ms |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  defp fmt_time(_ms), do: "--:--:--"

  defp truncate(text, max) do
    text = to_string(text)
    if String.length(text) <= max, do: text, else: String.slice(text, 0, max - 1) <> "…"
  end

  defp mesh_panel(system, _rect) do
    snapshot = system.mesh_snapshot || Mesh.local_snapshot()

    caption = %Title{
      content: " " <> Mesh.summary(snapshot) <> " ",
      position: :bottom,
      alignment: :right,
      style: Theme.style(:muted)
    }

    %{Mesh.canvas(snapshot) | block: panel_block("Mesh", [caption])}
  end

  # Eeva is a permanent one-liner ("local" or "attached ▸ node"), so it rides a
  # single borderless row above the status bar instead of owning a quadrant.
  defp eeva_widgets(rect) do
    [{%Paragraph{text: Attach.lines(), style: Theme.style(:base), wrap: false}, rect}]
  end

  # A right-edge scrollbar drawn on the panel's inner border column, or nothing
  # when the content already fits. `position` is the top line offset.
  defp scrollbar_widgets(rect, position, content_length, viewport) do
    max_scroll = max(content_length - viewport, 0)

    if max_scroll > 0 do
      scrollbar = %Scrollbar{
        orientation: :vertical_right,
        content_length: max_scroll,
        position: min(max(position, 0), max_scroll),
        viewport_content_length: viewport,
        thumb_style: Theme.style(:accent),
        track_style: Theme.style(:subtle)
      }

      sb_rect = %Rect{
        x: rect.x + rect.width - 1,
        y: rect.y + 1,
        width: 1,
        height: max(rect.height - 2, 1)
      }

      [{scrollbar, sb_rect}]
    else
      []
    end
  end

  defp panel_block(title, extra_titles) do
    %Block{
      title: title,
      titles: extra_titles,
      borders: [:all],
      border_type: :rounded,
      border_style: Theme.style(:border),
      title_style: Theme.style(:accent),
      padding: {1, 1, 0, 0}
    }
  end
end
