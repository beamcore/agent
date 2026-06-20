defmodule Beamcore.TUI.Components.Providers do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.{Form, Store}
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  @box_inner 74

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

  def mark_dirty(p), do: %{p | render_dirty?: true}
  def clear_dirty(p), do: %{p | render_dirty?: false}

  def render_items(p, width) when is_struct(p, __MODULE__),
    do: render_list_items(p, width)

  def handle_event(event, p) do
    case event do
      %ExRatatui.Event.Key{code: "backspace"} ->
        {:noreply, handle_backspace(p) |> mark_dirty()}

      %ExRatatui.Event.Key{code: code, modifiers: mods} ->
        {:noreply, handle_key(code, mods, p) |> mark_dirty()}

      _ ->
        {:noreply, p}
    end
  end

  defp render_list_items(p, width) do
    if p.adding?,
      do: Form.render(p.form, Theme.style(:muted), Theme.style(:accent), Theme.style(:base)),
      else: table_header() ++ render_rows(p, width)
  end

  defp table_header do
    subtle = Theme.style(:subtle)
    muted = Theme.style(:muted)

    [
      %Line{spans: [%Span{content: "   ╭─ provider #{dashes(62)}─╮", style: subtle}]},
      %Line{
        spans: [
          %Span{content: "   │  ", style: subtle},
          %Span{content: pad("name", 16), style: muted},
          %Span{content: pad("model", 20), style: muted},
          %Span{content: pad("url", 24), style: muted},
          %Span{content: "key", style: muted},
          %Span{content: "   │", style: subtle}
        ]
      },
      %Line{spans: [%Span{content: "   ├#{dashes(@box_inner)}┤", style: subtle}]}
    ]
  end

  defp render_rows(p, width) do
    accent = Theme.style(:accent)
    muted = Theme.style(:muted)
    base = Theme.style(:base)
    subtle = Theme.style(:subtle)
    r = rp(width)
    bottom = %Line{spans: [%Span{content: "   ╰#{dashes(@box_inner)}╯#{r}", style: subtle}]}

    if p.providers == [] do
      [
        %Line{
          spans: [
            %Span{content: "   │#{String.duplicate(" ", @box_inner - 1)}│#{r}", style: subtle}
          ]
        },
        %Line{
          spans: [
            %Span{content: "   │  no providers configured", style: muted},
            %Span{content: String.duplicate(" ", @box_inner - 30) <> "│#{r}", style: subtle}
          ]
        },
        %Line{
          spans: [
            %Span{content: "   │#{String.duplicate(" ", @box_inner - 1)}│#{r}", style: subtle}
          ]
        },
        bottom
      ]
    else
      active = Store.active(p.configure_for)

      rows =
        p.providers
        |> Enum.with_index()
        |> Enum.flat_map(fn {{name, config}, idx} ->
          sel? = idx == p.selected
          act? = name == active
          cur = if sel?, do: "▸", else: " "
          mark = if act?, do: "●", else: "○"
          ns = if sel?, do: accent, else: base
          ms = if act?, do: Theme.style(:done), else: muted
          model = Map.get(config, "default_model") || "—"
          url = Map.get(config, "base_url") || "—"
          key = if Map.get(config, "api_key"), do: "✓", else: "✗"
          ks = if key == "✓", do: Theme.style(:done), else: Theme.style(:error)

          [
            %Line{
              spans: [
                %Span{content: "   │ #{cur}", style: subtle},
                %Span{content: mark, style: ms},
                %Span{content: " #{pad(truncate(name, 14), 16)}", style: ns},
                %Span{content: pad(truncate(model, 18), 20), style: muted},
                %Span{content: pad(truncate(url, 22), 24), style: subtle},
                %Span{content: key, style: ks},
                %Span{content: "   │#{r}", style: subtle}
              ]
            }
          ]
        end)

      rows ++ [bottom]
    end
  end

  defp rp(width), do: String.duplicate(" ", max(width - @box_inner - 4, 0))
  defp dashes(n), do: String.duplicate("─", n)

  def handle_key("up", _mods, p), do: %{p | selected: max(p.selected - 1, 0)}

  def handle_key("down", _mods, p) do
    max_idx = max(length(p.providers) - 1, 0)
    %{p | selected: min(p.selected + 1, max_idx)}
  end

  def handle_key("a", _mods, %{adding?: false} = p), do: %{p | adding?: true, form: Form.new()}

  def handle_key("d", _mods, %{adding?: false} = p) do
    case Enum.at(p.providers, p.selected) do
      {name, _} ->
        Store.delete(name)
        providers = Store.load()
        %{p | providers: providers, selected: min(p.selected, max(length(providers) - 1, 0))}

      nil ->
        p
    end
  end

  def handle_key("enter", _mods, %{adding?: false} = p) do
    case Enum.at(p.providers, p.selected) do
      {name, config} ->
        Store.activate(name, config, p.configure_for)
        send(self(), {:refresh_session, p.configure_for})

      nil ->
        :ok
    end

    p
  end

  def handle_key(key, mods, %{adding?: true} = p) do
    case Form.handle_key(key, mods, p.form) do
      {:cancel, _} -> %{p | adding?: false, form: nil}
      {:saved, _} -> %{p | providers: Store.load(), adding?: false, form: nil}
      {:error, form} -> %{p | form: form}
      form -> %{p | form: form}
    end
  end

  def handle_key(_key, _mods, p), do: p

  def handle_backspace(%{adding?: true} = p),
    do: %{p | form: Form.handle_backspace(p.form)}

  def handle_backspace(p), do: p

  defp truncate(text, max_len) do
    text = to_string(text)
    if String.length(text) <= max_len, do: text, else: String.slice(text, 0, max_len - 1) <> "…"
  end

  defp pad(text, width) do
    text = to_string(text)
    if String.length(text) >= width, do: text, else: String.pad_trailing(text, width)
  end
end
