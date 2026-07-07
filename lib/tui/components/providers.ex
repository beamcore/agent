defmodule Beamcore.TUI.Components.Providers do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.{Form, Store}
  alias Beamcore.TUI.Events.KeyEvents
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.{Line, Span}

  defstruct screen_type: :providers,
            render_dirty?: true,
            configure_for: :agent,
            providers: [],
            active_provider: nil,
            selected: 0,
            adding?: false,
            form: nil,
            save_ref: nil,
            action_ref: nil

  def new(configure_for \\ :agent) do
    %__MODULE__{
      providers: Store.load(),
      active_provider: Store.active(configure_for),
      configure_for: configure_for
    }
  end

  def mark_dirty(p), do: %{p | render_dirty?: true}
  def clear_dirty(p), do: %{p | render_dirty?: false}

  def render_items(p, height \\ nil, width \\ nil) when is_struct(p, __MODULE__),
    do: render_list_items(p, height, width)

  def handle_event(%ExRatatui.Event.Mouse{}, p), do: {:noreply, p}

  def handle_event(event, p) do
    cond do
      paste_event?(event) ->
        content =
          Map.get(event, :content) || Map.get(event, "content") || Map.get(event, :text) || ""

        {:noreply, insert_text(p, content) |> mark_dirty()}

      match?(%ExRatatui.Event.Key{}, event) ->
        %ExRatatui.Event.Key{code: code, modifiers: mods} = event

        if KeyEvents.actionable?(event) do
          if code == "backspace" do
            {:noreply, handle_backspace(p) |> mark_dirty()}
          else
            {:noreply, handle_key(code, mods, p) |> mark_dirty()}
          end
        else
          {:noreply, p}
        end

      true ->
        {:noreply, p}
    end
  end

  defp paste_event?(event) when is_map(event) do
    struct_name = Map.get(event, :__struct__)
    name = if struct_name, do: Module.split(struct_name) |> List.last(), else: ""

    String.contains?(name, "Paste") or Map.has_key?(event, :content) or
      Map.has_key?(event, "content")
  end

  defp paste_event?(_), do: false

  defp render_list_items(p, height, width) do
    if p.adding?,
      do:
        Form.render(
          p.form,
          Theme.style(:muted),
          Theme.style(:accent),
          Theme.style(:base),
          height,
          width
        ),
      else: table_header() ++ render_rows(p)
  end

  defp table_header do
    subtle = Theme.style(:subtle)
    muted = Theme.style(:muted)

    [
      %Line{
        spans: [
          %Span{content: "  ", style: muted},
          %Span{content: pad("name", 16), style: muted},
          %Span{content: pad("model", 20), style: muted},
          %Span{content: pad("url", 24), style: muted},
          %Span{content: "key", style: muted}
        ]
      },
      %Line{
        spans: [%Span{content: "  " <> String.duplicate("─", 68), style: subtle}]
      }
    ]
  end

  defp render_rows(p) do
    accent = Theme.style(:accent)
    muted = Theme.style(:muted)
    base = Theme.style(:base)

    if p.providers == [] do
      [
        %Line{
          spans: [
            %Span{content: "  no providers configured", style: muted}
          ]
        }
      ]
    else
      p.providers
      |> Enum.with_index()
      |> Enum.flat_map(fn {{name, config}, idx} ->
        sel? = idx == p.selected
        act? = name == p.active_provider
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
              %Span{content: " #{cur}", style: accent},
              %Span{content: mark, style: ms},
              %Span{content: " #{pad(truncate(name, 14), 16)}", style: ns},
              %Span{content: pad(truncate(model, 18), 20), style: muted},
              %Span{content: pad(truncate(url, 22), 24), style: muted},
              %Span{content: key, style: ks}
            ]
          }
        ]
      end)
    end
  end

  def handle_key("up", _mods, p), do: %{p | selected: max(p.selected - 1, 0)}

  def handle_key("down", _mods, p) do
    max_idx = max(length(p.providers) - 1, 0)
    %{p | selected: min(p.selected + 1, max_idx)}
  end

  def handle_key("a", _mods, %{adding?: false} = p), do: %{p | adding?: true, form: Form.new()}

  def handle_key("d", _mods, %{adding?: false} = p) do
    case Enum.at(p.providers, p.selected) do
      {name, _} ->
        start_action(p, {:delete, name})

      nil ->
        p
    end
  end

  def handle_key("enter", _mods, %{adding?: false} = p) do
    case Enum.at(p.providers, p.selected) do
      {name, config} ->
        start_action(p, {:activate, name, config, p.configure_for})

      nil ->
        p
    end
  end

  def handle_key(key, mods, %{adding?: true} = p) do
    case Form.handle_key(key, mods, p.form) do
      {:cancel, _} -> %{p | adding?: false, form: nil}
      {:save, name, config, form} -> start_save(p, name, config, form)
      form -> %{p | form: form}
    end
  end

  def handle_key(_key, _mods, p), do: p

  def handle_backspace(%{adding?: true} = p),
    do: %{p | form: Form.handle_backspace(p.form)}

  def handle_backspace(p), do: p

  def insert_text(%{adding?: true} = p, text),
    do: %{p | form: Form.insert_text(p.form, text)}

  def insert_text(p, _text), do: p

  def finish_save(%{save_ref: ref} = p, ref, :ok) do
    %{
      p
      | providers: Store.load(),
        active_provider: Store.active(p.configure_for),
        adding?: false,
        form: nil,
        save_ref: nil
    }
  end

  def finish_save(%{save_ref: ref, form: form} = p, ref, {:error, reason}) do
    %{p | form: %{form | error: "save failed: #{format_reason(reason)}"}, save_ref: nil}
  end

  def finish_save(p, _ref, _result), do: p

  def finish_action(%{action_ref: ref} = p, ref, {:activate, screen_type}, :ok) do
    send(self(), {:refresh_session, screen_type})
    reload_provider_state(%{p | action_ref: nil})
  end

  def finish_action(%{action_ref: ref} = p, ref, :delete, :ok) do
    p
    |> Map.put(:action_ref, nil)
    |> reload_provider_state()
  end

  def finish_action(%{action_ref: ref} = p, ref, _action, {:error, reason}) do
    form = p.form || Form.new()

    %{
      p
      | form: %{form | error: "provider action failed: #{format_reason(reason)}"},
        action_ref: nil
    }
  end

  def finish_action(p, _ref, _action, _result), do: p

  defp start_save(%{save_ref: ref} = p, _name, _config, form) when is_reference(ref),
    do: %{p | form: form}

  defp start_save(p, name, config, form) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.start(fn ->
        result =
          try do
            Beamcore.Config.put_provider(name, config)
          rescue
            error ->
              Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :provider_save)
              {:error, Exception.message(error)}
          catch
            kind, reason ->
              Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :provider_save)
              {:error, reason}
          end

        send(parent, {:provider_saved, ref, result})
      end)

    %{p | form: %{form | error: "saving..."}, save_ref: ref}
  rescue
    error ->
      Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :provider_save_start)
      %{p | form: %{form | error: "save failed: #{Exception.message(error)}"}}
  catch
    kind, reason ->
      Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :provider_save_start)
      %{p | form: %{form | error: "save failed: #{format_reason(reason)}"}}
  end

  defp start_action(%{action_ref: ref} = p, _action) when is_reference(ref), do: p

  defp start_action(p, action) do
    parent = self()
    ref = make_ref()

    {:ok, _pid} =
      Task.start(fn ->
        result =
          try do
            run_action(action)
          rescue
            error ->
              Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :provider_action)
              {:error, Exception.message(error)}
          catch
            kind, reason ->
              Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :provider_action)
              {:error, reason}
          end

        send(parent, {:provider_action_done, ref, action_result_tag(action), result})
      end)

    %{p | action_ref: ref}
  rescue
    error ->
      Beamcore.AppLog.exception(:error, error, __STACKTRACE__, boundary: :provider_action_start)
      p
  catch
    kind, reason ->
      Beamcore.AppLog.exception(kind, reason, __STACKTRACE__, boundary: :provider_action_start)
      p
  end

  defp run_action({:delete, name}) do
    Store.delete(name)
    :ok
  end

  defp run_action({:activate, name, config, screen_type}) do
    Store.activate(name, config, screen_type)
    :ok
  end

  defp action_result_tag({:delete, _name}), do: :delete
  defp action_result_tag({:activate, _name, _config, screen_type}), do: {:activate, screen_type}

  defp reload_provider_state(p) do
    providers = Store.load()

    %{
      p
      | providers: providers,
        active_provider: Store.active(p.configure_for),
        selected: min(p.selected, max(length(providers) - 1, 0))
    }
  end

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp truncate(text, max_len) do
    text = to_string(text)
    if String.length(text) <= max_len, do: text, else: String.slice(text, 0, max_len - 1) <> "…"
  end

  defp pad(text, width) do
    text = to_string(text)
    if String.length(text) >= width, do: text, else: String.pad_trailing(text, width)
  end
end
