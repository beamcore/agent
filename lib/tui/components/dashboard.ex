defmodule Beamcore.TUI.Components.Dashboard do
  @moduledoc """
  The Dashboard (F2) body: a grid of native-bordered panels.

  Replaces the former hand-drawn System page. Each panel is a native
  `Block` (rounded border + title) wrapping its content; the grid is a
  two-by-two layout on wide terminals that collapses to a single column
  when the terminal is narrow. Panel content is fed entirely from data the
  dashboard state already owns — token stats, the provider store, the mesh
  snapshot, and the Eeva runtime status.
  """

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.System.{Attach, Mesh, Stats}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Layout, as: RatLayout
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.{Block, Paragraph, Table}
  alias ExRatatui.Widgets.Block.Title

  @narrow_width 88
  @activity_rows 20

  @doc """
  Builds the dashboard panel grid for `area`.

  Returns a list of `{widget, %Rect{}}` tuples — one per panel — laid out
  within `area`.
  """
  @spec panels(struct(), Rect.t()) :: [{Paragraph.t(), Rect.t()}]
  def panels(system, %Rect{width: width} = area) when width < @narrow_width do
    [usage, providers, activity, mesh, eeva] =
      RatLayout.split(area, :vertical, List.duplicate({:percentage, 20}, 5))

    build(system, usage, providers, activity, mesh, eeva)
  end

  def panels(system, %Rect{} = area) do
    [top, activity, bottom] =
      RatLayout.split(area, :vertical, [
        {:percentage, 34},
        {:percentage, 32},
        {:percentage, 34}
      ])

    [usage, providers] =
      RatLayout.split(top, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    [mesh, eeva] =
      RatLayout.split(bottom, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    build(system, usage, providers, activity, mesh, eeva)
  end

  defp build(system, usage_rect, providers_rect, activity_rect, mesh_rect, eeva_rect) do
    [
      {usage_panel(system, usage_rect), usage_rect},
      {providers_panel(system, providers_rect), providers_rect},
      {activity_panel(system, activity_rect), activity_rect},
      {mesh_panel(system, mesh_rect), mesh_rect},
      {eeva_panel(eeva_rect), eeva_rect}
    ]
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

  defp providers_panel(system, _rect) do
    p = system.providers

    if p.adding? do
      %Paragraph{
        text: Providers.form_lines(p),
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

  defp activity_panel(system, _rect) do
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
        %{activity_table(activity) | block: block}
    end
  end

  defp live_caption do
    %Title{content: " live ", position: :bottom, alignment: :right, style: Theme.style(:accent)}
  end

  defp activity_table(activity) do
    %Table{
      header: activity_header(),
      rows: activity |> Enum.take(@activity_rows) |> Enum.map(&activity_row/1),
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

  defp eeva_panel(_rect) do
    panel("Eeva Runtime", Attach.lines())
  end

  defp panel(title, lines) do
    %Paragraph{
      text: lines,
      style: Theme.style(:base),
      wrap: false,
      block: panel_block(title, [])
    }
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
