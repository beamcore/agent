defmodule Beamcore.TUI.Components.Providers do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.Form
  alias Beamcore.TUI.Components.Providers.Store
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}
  alias ExRatatui.Widgets.Paragraph

  defstruct screen_type: :providers,
            render_dirty?: true,
            configure_for: :agent,
            providers: [],
            selected: 0,
            adding?: false,
            form: nil

  def new(configure_for \\ :agent) do
    %__MODULE__{providers: Store.load(), configure_for: configure_for}
  end

  def render_text(f3, width) when is_struct(f3, __MODULE__),
    do: render_lines(f3, width)

  def widget(f3, area) when is_struct(f3, __MODULE__) do
    lines = render_lines(f3, area.width - 4)
    height = max(length(lines), 1)

    [
      {%Paragraph{text: lines, wrap: false}, height},
      {%Paragraph{text: [%Span{content: ""}], style: Theme.style(:subtle)}, 1}
    ]
  end

  def mark_dirty(f3), do: %{f3 | render_dirty?: true}
  def clear_dirty(f3), do: %{f3 | render_dirty?: false}

  def handle_event(event, f3) do
    case event do
      %ExRatatui.Event.Key{code: "backspace"} ->
        {:noreply, handle_backspace(f3) |> mark_dirty()}

      %ExRatatui.Event.Key{code: code, modifiers: mods} ->
        {:noreply, handle_key(code, mods, f3) |> mark_dirty()}

      _ ->
        {:noreply, f3}
    end
  end

  defp render_lines(f3, width) do
    if f3.adding?,
      do: Form.render(f3.form, Theme.style(:muted), Theme.style(:accent), Theme.style(:base)),
      else: render_list(f3, width)
  end

  defp render_list(f3, width) do
    accent = Theme.style(:accent)
    muted = Theme.style(:muted)
    subtle = Theme.style(:subtle)
    base = Theme.style(:base)
    sep = String.duplicate("─", max(width - 6, 4))
    active = Store.active(f3.configure_for)
    screen_label = if f3.configure_for == :agent, do: "F1", else: "F2"

    header = [
      %Line{spans: [%Span{content: ""}]},
      %Line{spans: [%Span{content: "  Providers", style: accent}]},
      %Line{spans: [%Span{content: "  #{sep}", style: subtle}]}
    ]

    table_header = [
      %Line{
        spans: [
          %Span{content: "      #{String.pad_trailing("name", 16)}", style: muted},
          %Span{content: String.pad_trailing("model", 20), style: muted},
          %Span{content: String.pad_trailing("url", 24), style: muted},
          %Span{content: "key", style: muted}
        ]
      },
      %Line{spans: [%Span{content: "  #{sep}", style: subtle}]}
    ]

    items =
      if f3.providers == [] do
        [
          %Line{spans: [%Span{content: ""}]},
          %Line{
            spans: [
              %Span{content: "    no providers configured", style: muted}
            ]
          }
        ]
      else
        f3.providers
        |> Enum.with_index()
        |> Enum.flat_map(fn {{name, config}, idx} ->
          selected? = idx == f3.selected
          is_active? = name == active
          cursor = if selected?, do: "▸ ", else: "  "
          active_mark = if is_active?, do: "● ", else: "  "
          style = if selected?, do: accent, else: base
          active_style = if is_active?, do: Theme.style(:done), else: muted

          model = Map.get(config, "default_model") || "—"
          url = Map.get(config, "base_url") || "—"
          has_key = if Map.get(config, "api_key"), do: "✓", else: "✗"

          name_col = String.pad_trailing(truncate(name, 14), 16)
          model_col = String.pad_trailing(truncate(model, 18), 20)
          url_col = String.pad_trailing(truncate(url, 22), 24)

          [
            %Line{
              spans: [
                %Span{content: "#{cursor}", style: style},
                %Span{content: "#{active_mark}", style: active_style},
                %Span{content: "#{name_col}", style: style},
                %Span{content: "#{model_col}", style: muted},
                %Span{content: "#{url_col}", style: subtle},
                %Span{
                  content: has_key,
                  style: if(has_key == "✓", do: Theme.style(:done), else: Theme.style(:error))
                }
              ]
            }
          ]
        end)
      end

    footer = [
      %Line{spans: [%Span{content: ""}]},
      %Line{spans: [%Span{content: "  #{sep}", style: subtle}]},
      %Line{
        spans: [
          %Span{content: "  configuring: ", style: muted},
          %Span{content: screen_label, style: accent},
          %Span{content: "   ", style: muted},
          %Span{content: "enter", style: accent},
          %Span{content: " activate   ", style: muted},
          %Span{content: "a", style: accent},
          %Span{content: " add   ", style: muted},
          %Span{content: "d", style: accent},
          %Span{content: " delete   ", style: muted},
          %Span{content: "F1", style: accent},
          %Span{content: " back", style: muted}
        ]
      }
    ]

    header ++ table_header ++ items ++ footer
  end

  def handle_key("up", _mods, f3), do: %{f3 | selected: max(f3.selected - 1, 0)}

  def handle_key("down", _mods, f3) do
    max_idx = max(length(f3.providers) - 1, 0)
    %{f3 | selected: min(f3.selected + 1, max_idx)}
  end

  def handle_key("a", _mods, %{adding?: false} = f3), do: %{f3 | adding?: true, form: Form.new()}

  def handle_key("d", _mods, %{adding?: false} = f3) do
    case Enum.at(f3.providers, f3.selected) do
      {name, _} ->
        Store.delete(name)
        providers = Store.load()
        %{f3 | providers: providers, selected: min(f3.selected, max(length(providers) - 1, 0))}

      nil ->
        f3
    end
  end

  def handle_key("enter", _mods, %{adding?: false} = f3) do
    case Enum.at(f3.providers, f3.selected) do
      {name, config} ->
        Store.activate(name, config, f3.configure_for)
        send(self(), {:refresh_session, f3.configure_for})

      nil ->
        :ok
    end

    f3
  end

  def handle_key(key, mods, %{adding?: true} = f3) do
    case Form.handle_key(key, mods, f3.form) do
      {:cancel, _} -> %{f3 | adding?: false, form: nil}
      {:saved, _} -> %{f3 | providers: Store.load(), adding?: false, form: nil}
      {:error, form} -> %{f3 | form: form}
      form -> %{f3 | form: form}
    end
  end

  def handle_key(_key, _mods, f3), do: f3

  def handle_backspace(%{adding?: true} = f3), do: %{f3 | form: Form.handle_backspace(f3.form)}
  def handle_backspace(f3), do: f3

  defp truncate(text, max_len) do
    text = to_string(text)
    if String.length(text) <= max_len, do: text, else: String.slice(text, 0, max_len - 1) <> "…"
  end
end
