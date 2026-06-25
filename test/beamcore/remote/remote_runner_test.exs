defmodule Beamcore.RemoteRunnerTest do
  use ExUnit.Case, async: true

  alias Beamcore.RemoteRunner

  defp quoted(code), do: Code.string_to_quoted!(code, file: "eeva", line: 1)

  defp run(code, limits \\ %{}) do
    code
    |> quoted()
    |> RemoteRunner.run(limits)
  end

  describe "successful evaluation" do
    test "returns the inspected result value" do
      assert %{status: :ok, result: result, stdout: ""} = run("1 + 2")
      assert result == "3"
    end

    test "captures stdout written to the group leader" do
      assert %{status: :ok, stdout: stdout, result: result} =
               run(~s|IO.puts("hello from runner"); :done|)

      assert stdout =~ "hello from runner"
      assert result == ":done"
    end

    test "auto-invokes a returned zero-arity function" do
      assert %{status: :ok, result: "42"} = run("fn -> 42 end")
    end

    test "merges compiler diagnostics into stdout" do
      assert %{status: :ok, stdout: stdout} = run("Enum.map([1], fn x -> 2 end)")
      assert stdout =~ "unused"
    end
  end

  describe "error handling" do
    test "a raised exception is captured as a serializable error" do
      assert %{status: :error, kind: :error, error: error, formatted: formatted} =
               run(~s|raise "boom"|)

      assert error =~ "boom"
      assert formatted =~ "boom"
      # Everything that crosses the wire must be a plain serializable term.
      assert is_binary(error) and is_binary(formatted)
    end

    test "a thrown value is captured with its kind" do
      assert %{status: :error, kind: :throw, error: error} = run("throw(:nope)")
      assert error =~ "nope"
    end
  end

  describe "resource limits" do
    test "an infinite loop trips the reduction limit" do
      assert %{status: :reduction_limit, reductions: reductions} =
               run(
                 "Stream.repeatedly(fn -> :ok end) |> Enum.each(fn _ -> :ok end)",
                 %{max_reductions: 100_000, timeout_ms: 5_000}
               )

      assert reductions > 100_000
    end

    @tag capture_log: true
    test "runaway allocation trips the memory limit" do
      assert %{status: :memory_limit} =
               run(
                 "Enum.reduce(1..50_000_000, [], fn i, acc -> [i | acc] end)",
                 %{max_memory_bytes: 8_000_000, timeout_ms: 5_000}
               )
    end

    test "a slow program trips the timeout" do
      assert %{status: :timeout, timeout_ms: 100} =
               run("Process.sleep(5_000)", %{timeout_ms: 100})
    end
  end

  describe "truncation" do
    test "oversized stdout is truncated to the byte budget" do
      assert %{status: :ok, stdout: stdout} =
               run(~s|IO.write(String.duplicate("x", 10_000)); :ok|, %{max_output_bytes: 500})

      assert byte_size(stdout) <= 600
      assert stdout =~ "[truncated]"
    end

    test "oversized result is truncated to the byte budget" do
      assert %{status: :ok, result: result} =
               run(~s|String.duplicate("y", 10_000)|, %{max_result_bytes: 500})

      assert byte_size(result) <= 600
      assert result =~ "[truncated]"
    end
  end

  describe "contract" do
    test "version is a positive integer" do
      assert is_integer(RemoteRunner.version()) and RemoteRunner.version() > 0
    end

    test "the module is self-contained (no other Beamcore.* modules referenced)" do
      # Injected onto foreign nodes that don't have BeamCore loaded, so the
      # compiled module must not reference any other Beamcore.* module. Every
      # referenced module appears in the BEAM atom table.
      {:ok, {_mod, [{:atoms, atoms}]}} =
        :beam_lib.chunks(:code.which(RemoteRunner), [:atoms])

      referenced =
        atoms
        |> Enum.map(fn {_id, atom} -> to_string(atom) end)
        |> Enum.filter(&String.starts_with?(&1, "Elixir.Beamcore"))
        |> Enum.reject(&(&1 == "Elixir.Beamcore.RemoteRunner"))

      assert referenced == []
    end
  end
end
