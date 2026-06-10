defmodule Beamcore.Agent.Core.ToolDisplayTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Core.ToolDisplay

  test "renders eeva code and result compactly" do
    args = %{"code" => "File.read!(\"README.md\")\n|> byte_size()"}
    result = Jason.encode!(%{"ok" => true, "summary" => "Eeva completed successfully."})

    event = ToolDisplay.activity("eeva", args, :done, result)
    assert event.name == "eeva"
    assert event.target == "Elixir"
    assert event.label =~ "File.read!"
    assert event.summary =~ "Eeva completed"
  end

  test "marks failed eeva results as errors" do
    result = Jason.encode!(%{"ok" => false, "summary" => "boom"})
    assert ToolDisplay.result_status(result) == :error
  end
end
