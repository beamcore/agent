defmodule Beamcore.Agent.Tools.ModifyValidationTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Modify

  @test_dir "test/tmp_modify_validation_test"
  @test_cases_path "validation/test_cases.json"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)
    on_exit(fn -> File.rm_rf!(@test_dir) end)
    :ok
  end

  # Load and decode test cases compile-time to generate tests
  cases =
    @test_cases_path
    |> File.read!()
    |> Jason.decode!()

  for tc <- cases do
    @tc tc

    test "validation case: #{@tc["id"]} - #{@tc["description"]}" do
      rel_file = @tc["file"]
      source_content = File.read!(rel_file)

      # Copy example file to temporary test directory
      filename = Path.basename(rel_file)
      test_file_path = Path.join(@test_dir, "#{@tc["id"]}_#{filename}")
      File.write!(test_file_path, source_content)

      params = %{
        "path" => test_file_path,
        "edits" => @tc["edits"]
      }

      result = Modify.execute(params)

      if @tc["expected_success"] do
        refute result =~ "Error:", "Expected success, but got error: #{result}"
        assert result =~ "Successfully updated", "Expected success message, but got: #{result}"

        if contains = @tc["contains"] do
          new_content = File.read!(test_file_path)
          assert new_content =~ contains, "Expected modified content to contain: #{contains}"
        end
      else
        assert result =~ "Error:", "Expected error, but got success: #{result}"
      end
    end
  end
end
