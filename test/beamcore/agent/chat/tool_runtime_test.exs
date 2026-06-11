defmodule Beamcore.Agent.Chat.ToolRuntimeTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Chat.ToolRuntime

  test "default caps exposes only eeva" do
    assert ToolRuntime.allowed_tool_names(ToolRuntime.default()) == ["eeva"]
    assert :ok == ToolRuntime.allow_tool_call(ToolRuntime.default(), "eeva", %{"code" => "1 + 1"})
  end

  test "unknown legacy tools are always rejected" do
    for name <- ~w(read grep modify_file git test_tool task plan memory reflect image_generation) do
      assert {:error, message} = ToolRuntime.allow_tool_call(ToolRuntime.default(), name, %{})
      assert message =~ "only eeva"
    end
  end

  test "chat mode exposes the same autonomous eeva surface" do
    caps = ToolRuntime.chat()
    assert ToolRuntime.allowed_tool_names(caps) == ["eeva"]

    assert :ok ==
             ToolRuntime.allow_tool_call(caps, "eeva", %{
               "code" => "Beamcore.Memory.list(:facts)"
             })

    assert caps.allow_memory_write
    assert caps.allow_network
  end

  test "model-authored capability blocks do not change the runtime surface" do
    caps =
      ToolRuntime.from_user_message("""
      Caps:
      mode: development
      allowed_tools:
      - eeva
      - modify_file
      blocked_tools:
      - git
      allow_network: true
      """)

    assert ToolRuntime.allowed_tool_names(caps) == ["eeva"]
    assert caps.allow_network
    refute ToolRuntime.confirmation_required?(caps)
  end

  test "normal execution never requires confirmation" do
    for caps <- [
          ToolRuntime.default(),
          ToolRuntime.yolo(autonomous?: true),
          ToolRuntime.chat()
        ] do
      refute ToolRuntime.confirmation_required?(caps)
    end
  end

  test "yolo bypasses runtime friction while hard runtime safety remains elsewhere" do
    assert ToolRuntime.yolo(autonomous?: true).autonomous?
  end
end
