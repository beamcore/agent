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
  alias ExRatatui.Widgets.{Block, Paragraph}
  alias ExRatatui.Widgets.Block.Title

  @narrow_width 88

  @doc """
  Builds the dashboard panel grid for `area`.

  Returns a list of `{widget, %Rect{}}` tuples — one per panel — laid out
  within `area`.
  """
  @spec panels(struct(), Rect.t()) :: [{Paragraph.t(), Rect.t()}]
  def panels(system, %Rect{width: width} = area) when width < @narrow_width do
    [usage, providers, mesh, eeva] =
      RatLayout.split(area, :vertical, [
        {:percentage, 25},
        {:percentage, 25},
        {:percentage, 25},
        {:percentage, 25}
      ])

    build(system, usage, providers, mesh, eeva)
  end

  def panels(system, %Rect{} = area) do
    [top, bottom] =
      RatLayout.split(area, :vertical, [{:percentage, 50}, {:percentage, 50}])

    [usage, providers] =
      RatLayout.split(top, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    [mesh, eeva] =
      RatLayout.split(bottom, :horizontal, [{:percentage, 50}, {:percentage, 50}])

    build(system, usage, providers, mesh, eeva)
  end

  defp build(system, usage_rect, providers_rect, mesh_rect, eeva_rect) do
    [
      {usage_panel(system, usage_rect), usage_rect},
      {providers_panel(system, providers_rect), providers_rect},
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

  defp mesh_panel(system, rect) do
    snapshot = system.mesh_snapshot || Mesh.local_snapshot()
    panel("Mesh", Mesh.render(snapshot, inner_width(rect)))
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

  # Border (1 each side) plus horizontal padding (1 each side).
  defp inner_width(%Rect{width: width}), do: max(width - 4, 1)
end
