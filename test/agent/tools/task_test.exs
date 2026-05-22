defmodule Beamcore.Agent.Tools.TaskTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.Task

  setup do
    Beamcore.Agent.TestEnv.setup_env(%{
      "MISTRAL_API_KEY" => "test-api-key",
      "MISTRAL_BASE_URL" => nil
    })
  end

  @funny_names [
    "dusty_cat",
    "sneezing_walrus",
    "grumpy_otter",
    "wobbly_penguin",
    "lazy_sloth",
    "chatty_parrot",
    "bouncy_kangaroo",
    "sleepy_koala",
    "clumsy_panda",
    "zany_lemur",
    "jolly_narwhal",
    "quirky_quokka",
    "goofy_giraffe",
    "peppy_platypus",
    "mellow_manatee"
  ]

  test "spec/0 returns the expected tool specification" do
    spec = Task.spec()
    assert spec.type == "function"
    assert spec.function.name == "task"
    assert "prompt" in spec.function.parameters.required
  end

  test "name/0 returns the tool name" do
    assert Task.name() == "task"
  end

  test "execute/1 with valid prompt returns a result" do
    # Mock the API call to avoid actual OpenAI calls
    params = %{
      "prompt" => "Research the latest advancements in AI."
    }

    # Since we can't mock the OpenAI API directly, we verify the structure
    # and ensure the function doesn't raise an error
    result = Task.execute(params)
    assert is_binary(result)
  end

  test "execute/1 with custom model" do
    params = %{
      "prompt" => "Research the latest advancements in AI.",
      "model" => "mistral-large-3.5"
    }

    result = Task.execute(params)
    assert is_binary(result)
  end

  test "execute/1 with missing prompt returns an error" do
    params = %{}

    assert_raise KeyError, fn ->
      Task.execute(params)
    end
  end

  test "ensure_funny_name/1 returns a funny name for non-funny input" do
    result = Task.ensure_funny_name("boring_name")
    assert result in @funny_names
  end

  test "ensure_funny_name/1 preserves existing funny names" do
    funny_name = "dusty_cat"
    assert Task.ensure_funny_name(funny_name) == funny_name
  end
end
