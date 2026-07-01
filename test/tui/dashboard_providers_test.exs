defmodule Beamcore.TUI.Components.DashboardProvidersTest do
  use ExUnit.Case, async: false

  alias Beamcore.TUI.Components.{Dashboard, Providers}
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.{Block, Paragraph, Table}

  defp providers_struct do
    %Providers{
      providers: [
        {"mistral",
         %{
           "default_model" => "large-latest",
           "base_url" => "https://api.mistral.ai/v1",
           "api_key" => "encrypted:abc"
         }},
        {"openai", %{"default_model" => "gpt-4o", "base_url" => "https://api.openai.com/v1"}}
      ],
      active_provider: "mistral",
      selected: 0,
      adding?: false
    }
  end

  defp cell_text(%{content: content}), do: content
  defp cell_text(content) when is_binary(content), do: content

  defp row_texts(row), do: Enum.map(row, &cell_text/1)

  describe "Providers.table/1" do
    test "renders one selectable row per provider with a header" do
      table = Providers.table(providers_struct())

      assert %Table{} = table
      header = Enum.map(table.header, &cell_text/1)
      assert "name" in header
      assert "model" in header
      assert "url" in header
      assert "key" in header

      assert length(table.rows) == 2
      assert length(table.widths) == length(table.header)
      assert table.selected == 0
      assert table.highlight_symbol == "▸ "
    end

    test "marks the active provider and key presence per row" do
      [mistral_row, openai_row] = Providers.table(providers_struct()).rows

      [mistral_status | _] = row_texts(mistral_row)
      [openai_status | _] = row_texts(openai_row)

      assert mistral_status == "●"
      assert openai_status == "○"

      assert List.last(row_texts(mistral_row)) == "✓"
      assert List.last(row_texts(openai_row)) == "✗"
    end

    test "an empty provider list renders an empty-state row and no selection" do
      table = Providers.table(%Providers{providers: [], selected: 0})

      assert table.selected == nil
      text = table.rows |> Enum.flat_map(&row_texts/1) |> Enum.join(" ")
      assert text =~ "no providers"
    end
  end

  describe "the Providers dashboard panel" do
    defp providers_panel(system) do
      area = %Rect{x: 0, y: 0, width: 120, height: 30}
      {widget, _rect} = Dashboard.panels(system, area) |> Enum.at(1)
      widget
    end

    test "is a native Table wrapped in the Providers block when browsing" do
      system = %{TuiSystem.new(:agent) | providers: providers_struct()}
      widget = providers_panel(system)

      assert %Table{block: %Block{title: "Providers"}} = widget

      bottom_titles = Enum.filter(widget.block.titles, &(&1.position == :bottom))
      hint = bottom_titles |> Enum.map(& &1.content) |> Enum.join(" ")
      assert hint =~ "activate"
      assert hint =~ "add"
      assert hint =~ "delete"
    end

    test "falls back to the form paragraph while adding a provider" do
      adding = %{providers_struct() | adding?: true, form: Providers.Form.new()}
      system = %{TuiSystem.new(:agent) | providers: adding}

      assert %Paragraph{block: %Block{title: "Providers"}} = providers_panel(system)
    end
  end
end
