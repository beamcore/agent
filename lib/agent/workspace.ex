defmodule Beamcore.Agent.Workspace do
  @moduledoc """
  Workspace discovery and context detection for the agent.
  
  This module provides a centralized way to detect:
  - Git repository information (org/repo) from .git directory contents
  - Project type and build system
  - Current working directory context
  
  It does NOT execute shell commands - it only reads filesystem contents.
  This makes it fast, portable, and testable.
  """

  @type context :: {String.t(), String.t()} | nil
  @type project_type :: :elixir | :erlang | :python | :node | :go | :rust | :terraform | :ruby | :unknown
  @type build_system :: :make | :mix | :npm | :yarn | :pnpm | :cargo | :go | :bazel | :gradle | :maven | :pip | :unknown



  @doc """
  Checks if currently in a git repository.
  """
  @spec in_git_repo?() :: boolean()
  def in_git_repo? do
    !is_nil(detect_context())
  end

  @doc """
  Gets the current workspace context for the agent.
  Returns {org, repo} tuple if in a git repository, nil otherwise.
  
  This is the main entry point for agent tools that need workspace context.
  It checks environment variables first (for testing/override), then git detection.
  """
  @spec current_context() :: context()
  def current_context do
    # Check environment variables first (for testing and override scenarios)
    env_org = System.get_env("BEAMCORE_ORG")
    env_repo = System.get_env("BEAMCORE_REPO")

    if env_org && env_repo do
      {env_org, env_repo}
    else
      detect_git_context()
    end
  end

  @doc """
  Detects the current git repository context by reading .git directory.
  Returns {org, repo} tuple if in a git repository, nil otherwise.
  Does NOT use shell commands - only filesystem operations.
  """
  @spec detect_git_context() :: context() | nil
  def detect_git_context do
    # Check if .git directory exists
    case File.stat(".git", time: :posix) do
      {:ok, _stat} ->
        # .git is a directory, read config
        read_git_config()
      
      {:error, :enoent} ->
        # Check if .git is a file (submodule case)
        case File.read(".git") do
          {:ok, content} ->
            # .git is a file pointing to gitdir
            gitdir = String.trim(content)
            case File.stat(gitdir, time: :posix) do
              {:ok, _stat} -> read_git_config_from_dir(gitdir)
              {:error, _} -> nil
            end
          {:error, _} -> nil
        end
      
      {:error, _} ->
        nil
    end
  end

  @doc """
  Detects the project type based on filesystem contents.
  """
  @spec detect_project_type() :: project_type()
  def detect_project_type do
    cond do
      File.exists?("mix.exs") -> :elixir
      File.exists?("rebar.config") -> :erlang
      File.exists?("pyproject.toml") || File.exists?("setup.py") || File.exists?("requirements.txt") -> :python
      File.exists?("package.json") -> :node
      File.exists?("go.mod") -> :go
      File.exists?("Cargo.toml") -> :rust
      File.exists?(".terraform") || File.exists?("terraform.tf") -> :terraform
      File.exists?("Gemfile") -> :ruby
      true -> :unknown
    end
  end

  @doc """
  Detects the build system for the current project.
  """
  @spec detect_build_system() :: build_system()
  def detect_build_system do
    cond do
      File.exists?("Makefile") -> :make
      File.exists?("mix.exs") -> :mix
      File.exists?("package.json") && File.exists?("yarn.lock") -> :yarn
      File.exists?("package.json") && File.exists?("pnpm-lock.yaml") -> :pnpm
      File.exists?("package.json") -> :npm
      File.exists?("Cargo.toml") -> :cargo
      File.exists?("go.mod") -> :go
      File.exists?("BUILD") || File.exists?("WORKSPACE") -> :bazel
      File.exists?("build.gradle") -> :gradle
      File.exists?("pom.xml") -> :maven
      File.exists?("pyproject.toml") || File.exists?("setup.py") -> :pip
      true -> :unknown
    end
  end

  @doc """
  Gets the current working directory.
  """
  @spec current_dir() :: String.t()
  def current_dir do
    File.cwd!()
  end

  # --- Private helpers ---

  defp read_git_config do
    read_git_config_from_dir(".git")
  end

  defp read_git_config_from_dir(git_dir) do
    # Read .git/config to get remote URL
    config_path = Path.join(git_dir, "config")
    
    case File.read(config_path) do
      {:ok, content} ->
        parse_git_config(content)
      {:error, _} -> nil
    end
  end

  defp parse_git_config(content) do
    # Parse git config to find remote.origin.url
    content
    |> String.split("\n")
    |> Enum.reduce(nil, fn line, acc ->
      case String.trim(line) do
        "[remote \"origin\"]" -> :origin_section
        _ ->
          if acc == :origin_section && String.starts_with?(line, "url =") do
            url = String.trim(String.replace_prefix(line, "url = "))
            parse_git_url(url)
          else
            acc
          end
      end
    end)
  end

  defp parse_git_url(url) do
    # Remove .git suffix
    url = String.replace_suffix(url, ".git", "")
    
    # Handle various URL formats
    cond do
      # SSH: git@github.com:org/repo
      String.starts_with?(url, "git@") ->
        parse_ssh_url(url)
      
      # HTTPS: https://github.com/org/repo
      String.starts_with?(url, "http") ->
        parse_https_url(url)
      
      # File path: /path/to/repo or ./repo
      String.starts_with?(url, "/") || String.starts_with?(url, "./") ->
        parse_file_url(url)
      
      true -> nil
    end
  end

  defp parse_ssh_url(url) do
    # git@github.com:org/repo
    case String.split(url, [":", "/"]) do
      ["git@github.com", org, repo] -> {org, repo}
      ["git@gitlab.com", org, repo] -> {org, repo}
      ["git@bitbucket.org", org, repo] -> {org, repo}
      _ -> nil
    end
  end

  defp parse_https_url(url) do
    # https://github.com/org/repo
    # Remove protocol
    url = String.replace_prefix(url, "https://", "")
    url = String.replace_prefix(url, "http://", "")
    
    # Remove trailing slash
    url = String.replace_suffix(url, "/", "")
    
    parts = String.split(url, "/")
    
    case parts do
      [host, org, repo] when host in ["github.com", "gitlab.com", "bitbucket.org"] ->
        {org, repo}
      _ ->
        # Try to extract last two parts as org/repo
        case Enum.reverse(parts) do
          [repo, org | _] -> {org, repo}
          _ -> nil
        end
    end
  end

  defp parse_file_url(url) do
    # /path/to/repo or ./repo
    # Try to extract repo name from path
    parts = String.split(url, ["/", "."])
    case Enum.reverse(parts) do
      [repo | _] -> {"local", repo}
      _ -> nil
    end
  end

  defp has_elixir_files? do
    File.ls!()
    |> Enum.any?(fn file ->
      String.ends_with?(file, ".ex") || String.ends_with?(file, ".exs")
    rescue
      _ -> false
    end)
  end
end
