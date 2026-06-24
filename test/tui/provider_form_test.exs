defmodule Beamcore.TUI.ProviderFormTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Beamcore.TUI.Components.Providers
  alias Beamcore.TUI.Components.Providers.Form
  alias Beamcore.TUI.Components.System, as: TuiSystem
  alias Beamcore.TUI.{MessageRouter, MultiScreenState, State}

  @repo_root Path.expand("../..", __DIR__)

  defp key(code, mods \\ []) do
    %ExRatatui.Event.Key{code: code, kind: "press", modifiers: mods}
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamcore_provider_form_#{System.unique_integer([:positive])}.dets"
      )

    previous_path = Application.get_env(:beamcore, :config_dets_path)
    Application.put_env(:beamcore, :config_dets_path, path)

    on_exit(fn ->
      restore_config_path(previous_path)
      File.rm(path)
    end)

    :ok
  end

  test "down arrow moves focus to the next provider config input" do
    form = Form.new()

    form = Form.handle_key("down", [], form)
    assert form.field == :key

    form = Form.handle_key("down", [], form)
    assert form.field == :url
  end

  test "up arrow moves focus to the previous provider config input without wrapping" do
    form = Form.new()
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)

    form = Form.handle_key("up", [], form)
    assert form.field == :key

    form = Form.handle_key("up", [], form)
    assert form.field == :name

    form = Form.handle_key("up", [], form)
    assert form.field == :name
  end

  test "hidden disabled and non-editable fields are skipped" do
    form =
      Form.new(
        fields: [
          %{id: :name, label: "name"},
          %{id: :key, label: "api key", hidden?: true},
          %{id: :url, label: "base url", disabled?: true},
          %{id: :model, label: "model", editable?: false},
          %{id: :token_url, label: "token url"}
        ]
      )

    form = Form.handle_key("down", [], form)
    assert form.field == :token_url

    form = Form.handle_key("up", [], form)
    assert form.field == :name
  end

  test "focus remains visible when navigating a clipped form" do
    form =
      Form.new()
      |> Map.put(:visible_rows, 7)

    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)

    assert form.field == :token_url
    assert form.scroll_offset > 0

    lines =
      form
      |> Form.render(
        Beamcore.TUI.Theme.style(:muted),
        Beamcore.TUI.Theme.style(:accent),
        Beamcore.TUI.Theme.style(:base),
        7
      )
      |> rendered_text()

    assert lines =~ "token url"
    refute lines =~ "name *"
  end

  test "typing edits only the focused provider input" do
    form = Form.new()
    form = Form.handle_key("down", [], form)

    form = Form.handle_key("s", [], form)
    form = Form.handle_key("k", [], form)

    assert form.field == :key
    assert form.key == "sk"
    assert form.name == ""
  end

  test "provider selection behavior is not regressed" do
    providers = %Providers{providers: [{"one", %{}}, {"two", %{}}], selected: 0}

    providers = Providers.handle_key("down", [], providers)
    assert providers.selected == 1

    providers = Providers.handle_key("down", [], providers)
    assert providers.selected == 1

    providers = Providers.handle_key("up", [], providers)
    assert providers.selected == 0
  end

  test "existing F3 global shortcuts still work" do
    state = %MultiScreenState{
      active_screen: :f3,
      f1_state: %{screen_type: :agent, render_dirty?: false},
      f2_state: %{screen_type: :chat, render_dirty?: false},
      f3_state: TuiSystem.new(:agent)
    }

    {:noreply, updated} = Beamcore.TUI.handle_event(key("f1"), state)
    assert updated.active_screen == :f1
  end

  test "F3 tick starts mesh refresh asynchronously without blocking render loop" do
    state = %MultiScreenState{
      active_screen: :f3,
      f1_state: %{screen_type: :agent, render_dirty?: false},
      f2_state: %{screen_type: :chat, render_dirty?: false},
      f3_state: TuiSystem.new(:agent)
    }

    {elapsed_us, {:noreply, updated}} = :timer.tc(fn -> MessageRouter.route_tick(state) end)

    assert elapsed_us < 50_000
    assert is_reference(updated.f3_state.mesh_refresh_ref)
  end

  test "mesh snapshot result updates F3 state without stale refs" do
    ref = make_ref()
    system = %{TuiSystem.new(:agent) | mesh_refresh_ref: ref}

    state = %MultiScreenState{
      active_screen: :f3,
      f1_state: %{screen_type: :agent, render_dirty?: false},
      f2_state: %{screen_type: :chat, render_dirty?: false},
      f3_state: system
    }

    snapshot = Beamcore.TUI.Components.System.Mesh.local_snapshot()

    {:noreply, updated} = MessageRouter.route_system_mesh_snapshot(ref, snapshot, state)

    assert updated.f3_state.mesh_snapshot == snapshot
    assert updated.f3_state.mesh_refresh_ref == nil
  end

  test "provider form resize keeps focused input visible" do
    system = TuiSystem.new(:agent)
    {:noreply, system} = TuiSystem.handle_event(key("a"), system)
    form = system.providers.form
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)
    form = Form.handle_key("down", [], form)
    system = %{system | providers: %{system.providers | form: form}}

    state = %MultiScreenState{
      active_screen: :f3,
      f1_state: %State{textarea: ExRatatui.textarea_new()},
      f2_state: %State{textarea: ExRatatui.textarea_new()},
      f3_state: system
    }

    {:noreply, resized, [render?: false]} =
      Beamcore.TUI.handle_event(%ExRatatui.Event.Resize{width: 80, height: 16}, state)

    lines = TuiSystem.render_text(resized.f3_state, 76, 15) |> rendered_text()

    assert resized.f3_state.providers.form.field == :token_url
    assert lines =~ "token url"
  end

  test "provider save key path does not write directly to stdout or stderr" do
    form = %{
      Form.new()
      | name: "capture-test",
        key: "secret",
        url: "https://example.test/v1",
        model: "model-a"
    }

    providers = %Providers{adding?: true, form: form}

    parent = self()

    stdout =
      capture_io(fn ->
        send(parent, {:save_result, Providers.handle_key("enter", [], providers)})
      end)

    assert stdout == ""
    assert_receive {:save_result, %{save_ref: ref}}
    assert_receive {:provider_saved, ^ref, :ok}

    provider_sources =
      [
        "lib/tui/components/providers.ex",
        "lib/tui/components/providers/form.ex",
        "lib/tui/components/system.ex"
      ]
      |> Enum.map(&File.read!(Path.join(@repo_root, &1)))
      |> Enum.join("\n")

    refute provider_sources =~ "IO.puts"
    refute provider_sources =~ "IO.write"
    refute provider_sources =~ "IO.warn"
  end

  defp rendered_text(lines) do
    lines
    |> Enum.flat_map(& &1.spans)
    |> Enum.map_join("\n", & &1.content)
  end

  defp restore_config_path(nil), do: Application.delete_env(:beamcore, :config_dets_path)
  defp restore_config_path(path), do: Application.put_env(:beamcore, :config_dets_path, path)
end
