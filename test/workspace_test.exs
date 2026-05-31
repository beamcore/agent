defmodule Beamcore.Agent.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Beamcore.Agent.Workspace

  @test_dir "tmp/workspace_test"

  defp with_env(keys, values, fun) do
    # Save old values
    old_values = Enum.map(keys, &System.get_env/1)
    
    # Set new values
    Enum.map(keys, values, fn key, value -> System.put_env(key, value) end)
    
    try do
      fun.()
    after
      # Restore old values
      Enum.map(keys, old_values, fn key, old_value ->
        if old_value do
          System.put_env(key, old_value)
        else
          System.delete_env(key)
        end
      end)
    end
  end

  setup do
    # Create test directory
    File.mkdir_p!(@test_dir)
    File.cd!(@test_dir)
    
    on_exit(fn ->
      File.cd!("/")
      File.rm_rf!(@test_dir)
    end)
    
    :ok
  end

  test "current_context returns nil when not in git repo" do
    # Clear any env vars that might be set
    with_env(["BEAMCORE_ORG", "BEAMCORE_REPO"], [nil, nil], fn ->
      assert nil == Workspace.current_context()
    end)
  end

  test "detect_git_context returns nil when not in git repo" do
    assert nil == Workspace.detect_git_context()
  end

  test "detect_git_context reads from .git/config" do
    # Create a .git/config file
    File.mkdir_p!(".git")
    config_content = """
[core]
	repositoryformatversion = 0
[remote "origin"]
	url = git@github.com:org/repo.git
	fetch = +refs/heads/*:refs/remotes/origin/*
"""
    File.write!(".git/config", config_content)
    
    assert Workspace.detect_git_context() == {"org", "repo"}
  end

  test "detect_git_context handles submodule .git file" do
    # Create a .git file pointing to a gitdir
    gitdir = Path.join(@test_dir, "actual_git")
    File.mkdir_p!(gitdir)
    
    # Create config in the actual git dir
    config_content = """
[core]
	repositoryformatversion = 0
[remote "origin"]
	url = https://github.com/submodule_org/submodule_repo.git
"""
    File.write!(Path.join(gitdir, "config"), config_content)
    
    # Create .git file pointing to gitdir
    File.write!(".git", gitdir)
    
    assert Workspace.detect_git_context() == {"submodule_org", "submodule_repo"}
  end

  test "in_git_repo? returns false when not in git repo" do
    with_env(["BEAMCORE_ORG", "BEAMCORE_REPO"], [nil, nil], fn ->
      refute Workspace.in_git_repo?()
    end)
  end

  test "current_context uses environment variables when set" do
    with_env(["BEAMCORE_ORG", "BEAMCORE_REPO"], ["env_org", "env_repo"], fn ->
      assert Workspace.current_context() == {"env_org", "env_repo"}
    end)
  end

  test "current_context ignores git repo when env vars are set" do
    # Create a .git directory
    File.mkdir_p!(".git")
    File.mkdir_p!(Path.join(".git", "config"))
    
    with_env(["BEAMCORE_ORG", "BEAMCORE_REPO"], ["env_org", "env_repo"], fn ->
      # Even with .git present, env vars should take precedence
      assert Workspace.current_context() == {"env_org", "env_repo"}
    end)
  end

  test "detect_project_type detects Elixir project with mix.exs" do
    File.write!("mix.exs", "defmodule MyApp.Mixfile do\nend")
    assert :elixir == Workspace.detect_project_type()
  end

  test "detect_project_type detects Erlang project with rebar.config" do
    File.write!("rebar.config", "{erlang_opts, []}.")
    assert :erlang == Workspace.detect_project_type()
  end

  test "detect_project_type detects Node project" do
    File.write!("package.json", '{"name": "test"}')
    assert :node == Workspace.detect_project_type()
  end

  test "detect_project_type detects Python project" do
    File.write!("pyproject.toml", "[tool.poetry]\nname = \"test\"")
    assert :python == Workspace.detect_project_type()
  end

  test "detect_project_type detects Go project" do
    File.write!("go.mod", "module test")
    assert :go == Workspace.detect_project_type()
  end

  test "detect_project_type detects Rust project" do
    File.write!("Cargo.toml", "[package]\nname = \"test\"")
    assert :rust == Workspace.detect_project_type()
  end

  test "detect_project_type detects Terraform project" do
    File.mkdir_p!(".terraform")
    assert :terraform == Workspace.detect_project_type()
  end

  test "detect_project_type detects Ruby project" do
    File.write!("Gemfile", "source 'https://rubygems.org'\ngem 'rails'")
    assert :ruby == Workspace.detect_project_type()
  end

  test "detect_project_type returns unknown for empty directory" do
    assert :unknown == Workspace.detect_project_type()
  end

  test "detect_build_system detects Makefile" do
    File.write!("Makefile", "all:\n\techo hello")
    assert :make == Workspace.detect_build_system()
  end

  test "detect_build_system detects mix.exs" do
    File.write!("mix.exs", "defmodule MyApp.Mixfile do\nend")
    assert :mix == Workspace.detect_build_system()
  end

  test "detect_build_system detects yarn" do
    File.write!("package.json", '{"name": "test"}')
    File.write!("yarn.lock", "")
    assert :yarn == Workspace.detect_build_system()
  end

  test "detect_build_system detects pnpm" do
    File.write!("package.json", '{"name": "test"}')
    File.write!("pnpm-lock.yaml", "")
    assert :pnpm == Workspace.detect_build_system()
  end

  test "detect_build_system detects npm" do
    File.write!("package.json", '{"name": "test"}')
    File.write!("package-lock.json", '{}')
    assert :npm == Workspace.detect_build_system()
  end

  test "detect_build_system detects cargo" do
    File.write!("Cargo.toml", "[package]\nname = \"test\"")
    assert :cargo == Workspace.detect_build_system()
  end

  test "detect_build_system detects go" do
    File.write!("go.mod", "module test")
    assert :go == Workspace.detect_build_system()
  end

  test "detect_build_system detects bazel" do
    File.write!("BUILD", "cc_library(name = \"test\")")
    assert :bazel == Workspace.detect_build_system()
  end

  test "detect_build_system detects gradle" do
    File.write!("build.gradle", "plugins { id 'java' }")
    assert :gradle == Workspace.detect_build_system()
  end

  test "detect_build_system detects maven" do
    File.write!("pom.xml", "<project><groupId>test</groupId></project>")
    assert :maven == Workspace.detect_build_system()
  end

  test "detect_build_system detects pip" do
    File.write!("pyproject.toml", "[tool.poetry]\nname = \"test\"")
    assert :pip == Workspace.detect_build_system()
  end

  test "current_dir returns current working directory" do
    assert String.ends_with?(Workspace.current_dir(), @test_dir)
  end

  test "parse_git_url handles SSH URLs" do
    assert Workspace.parse_git_url("git@github.com:org/repo.git") == {"org", "repo"}
    assert Workspace.parse_git_url("git@gitlab.com:org/repo.git") == {"org", "repo"}
  end

  test "parse_git_url handles HTTPS URLs" do
    assert Workspace.parse_git_url("https://github.com/org/repo.git") == {"org", "repo"}
    assert Workspace.parse_git_url("https://github.com/org/repo") == {"org", "repo"}
  end

  test "parse_git_url handles file paths" do
    result = Workspace.parse_git_url("/path/to/repo")
    assert result == {"local", "repo"}
  end

  test "parse_git_url returns nil for invalid URLs" do
    assert nil == Workspace.parse_git_url("invalid")
    assert nil == Workspace.parse_git_url("")
  end

  test "parse_git_config extracts origin URL" do
    config = """
[core]
	repositoryformatversion = 0
[remote "origin"]
	url = git@github.com:org/repo.git
	fetch = +refs/heads/*:refs/remotes/origin/*
"""
    assert Workspace.parse_git_config(config) == {"org", "repo"}
  end

  test "parse_git_config returns nil when no origin" do
    config = """
[core]
	repositoryformatversion = 0
"""
    assert nil == Workspace.parse_git_config(config)
  end

  test "parse_git_config returns nil when origin has no URL" do
    config = """
[core]
	repositoryformatversion = 0
[remote "origin"]
	fetch = +refs/heads/*:refs/remotes/origin/*
"""
    assert nil == Workspace.parse_git_config(config)
  end
end
