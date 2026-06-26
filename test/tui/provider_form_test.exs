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

  test "OAuth2 fields are hidden until token url is entered" do
    form = Form.new()

    assert Form.visible_fields(form) |> Enum.map(& &1.id) == [
             :name,
             :key,
             :url,
             :model,
             :token_url
           ]

    form =
      %{form | field: :token_url}
      |> Form.insert_text("https://auth.example/token")

    assert Form.visible_fields(form) |> Enum.map(& &1.id) == [
             :name,
             :key,
             :url,
             :model,
             :token_url,
             :client_id,
             :client_secret,
             :scope,
             :token_request_id_header,
             :cacertfile,
             :ssl_verify
           ]
  end

  test "OAuth2 fields are skipped again when token url is cleared" do
    form =
      %{Form.new() | token_url: "x", mode: :oauth2, field: :scope}
      |> Form.insert_text("scope-a")

    assert form.field == :scope
    assert Enum.any?(Form.visible_fields(form), &(&1.id == :scope))

    form =
      %{form | field: :token_url}
      |> Form.handle_backspace()

    refute Enum.any?(Form.visible_fields(form), &(&1.id == :scope))
    assert form.field == :token_url
  end

  test "OAuth2 provider form saves generic auth and TLS fields" do
    form = %{
      Form.new()
      | name: "oauth-provider",
        url: "https://compatible.example/v1",
        model: "chat-model",
        token_url: "https://auth.example/token",
        client_id: "client",
        client_secret: "secret",
        scope: "CHAT_API_SCOPE",
        token_request_id_header: "RqUID",
        cacertfile: "/tmp/provider-ca.pem"
    }

    assert {:save, "oauth-provider", config, _form} = Form.handle_key("enter", [], form)

    assert config["auth"] == "oauth2"
    assert config["token_url"] == "https://auth.example/token"
    assert config["client_id"] == "client"
    assert config["client_secret"] == "secret"
    assert config["scope"] == "CHAT_API_SCOPE"
    assert config["token_request_id_header"] == "RqUID"
    assert config["cacertfile"] == "/tmp/provider-ca.pem"
    assert config["ssl_verify"] == "auto"
    refute Map.has_key?(config, "api_key")
  end

  test "OAuth2 provider form supports pre-encoded Basic credential in api key" do
    form = %{
      Form.new()
      | name: "oauth-provider",
        key: "preencoded-basic-key",
        url: "https://compatible.example/v1",
        model: "chat-model",
        token_url: "https://auth.example/token"
    }

    assert {:save, "oauth-provider", config, _form} = Form.handle_key("enter", [], form)

    assert config["auth"] == "oauth2"
    assert config["api_key"] == "preencoded-basic-key"
    refute Map.has_key?(config, "client_id")
    refute Map.has_key?(config, "client_secret")
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

    # This guards against accidentally running mesh collection synchronously in
    # the render tick while allowing normal CI scheduler variance around Task.start/1.
    assert elapsed_us < 250_000
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
    assert_receive {:provider_saved, ^ref, :ok}, 1_000

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
