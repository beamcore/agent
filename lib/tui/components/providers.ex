defmodule Beamcore.TUI.Components.Providers do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.{Form, Store}
  alias Beamcore.TUI.Events.KeyEvents
  alias Beamcore.TUI.Theme
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Table

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

  @doc "The provider list as a native selectable `Table` (browsing mode)."
  def table(p) when is_struct(p, __MODULE__) do
    %Table{
      header: header_cells(),
      rows: provider_rows(p),
      widths: [
        {:length, 1},
        {:length, 16},
        {:length, 18},
        {:fill, 1},
        {:length, 3}
      ],
      column_spacing: 1,
      selected: selection(p),
      highlight_style: Theme.style(:accent),
      highlight_symbol: "▸ ",
      style: Theme.style(:base)
    }
  end

  @doc "The add/edit provider form as content lines (adding mode)."
  def form_lines(p, height \\ nil) when is_struct(p, __MODULE__) do
    Form.render(p.form, Theme.style(:muted), Theme.style(:accent), Theme.style(:base), height)
  end

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

  defp header_cells do
    muted = Theme.style(:muted)

    for label <- ["", "name", "model", "url", "key"] do
      %Span{content: label, style: muted}
    end
  end

  defp selection(%{providers: []}), do: nil

  defp selection(%{providers: providers, selected: selected}) do
    selected |> max(0) |> min(length(providers) - 1)
  end

  defp provider_rows(%{providers: []}) do
    muted = Theme.style(:muted)

    [
      [
        %Span{content: "", style: muted},
        %Span{content: "no providers configured", style: muted},
        %Span{content: "", style: muted},
        %Span{content: "", style: muted},
        %Span{content: "", style: muted}
      ]
    ]
  end

  defp provider_rows(%{providers: providers} = p) do
    Enum.map(providers, fn {name, config} -> provider_row(name, config, p) end)
  end

  defp provider_row(name, config, p) do
    active? = name == p.active_provider
    key? = not is_nil(Map.get(config, "api_key"))

    [
      %Span{content: if(active?, do: "●", else: "○"), style: mark_style(active?)},
      %Span{content: truncate(name, 15), style: name_style(active?)},
      %Span{
        content: truncate(Map.get(config, "default_model") || "—", 17),
        style: Theme.style(:muted)
      },
      %Span{content: Map.get(config, "base_url") || "—", style: Theme.style(:muted)},
      %Span{content: if(key?, do: "✓", else: "✗"), style: key_style(key?)}
    ]
  end

  defp mark_style(true), do: Theme.style(:done)
  defp mark_style(false), do: Theme.style(:muted)

  defp name_style(true), do: Theme.style(:accent)
  defp name_style(false), do: Theme.style(:base)

  defp key_style(true), do: Theme.style(:done)
  defp key_style(false), do: Theme.style(:error)

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
end
