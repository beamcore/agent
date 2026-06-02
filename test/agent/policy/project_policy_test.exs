defmodule Beamcore.Agent.Policy.ProjectPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{Dispatcher, Fs, Glob, Grep, Modify, Read, Tree}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "beamcore_project_policy_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    previous = File.cwd!()
    File.cd!(tmp)
    Beamcore.Agent.TestPolicyRoot.setup(tmp)

    on_exit(fn ->
      File.cd!(previous)
      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  test "missing config preserves default behavior" do
    policy = ProjectPolicy.load()

    refute policy.loaded?
    assert :ok == ProjectPolicy.allowed_read_path?(policy, "README.md")
    assert :ok == ProjectPolicy.allowed_write_path?(policy, "scratch/a.ex")
  end

  test "init creates policy from example and save writes valid JSON" do
    File.mkdir_p!(".beamcore")

    File.cp!(
      Path.join(previous_repo_root(), ".beamcore/policy.example.json"),
      ".beamcore/policy.example.json"
    )

    assert {:ok, policy} = ProjectPolicy.init()
    assert policy.loaded?
    assert File.exists?(".beamcore/policy.json")

    decoded = Jason.decode!(File.read!(".beamcore/policy.json"))
    assert decoded["deny_paths"] == policy.deny_paths
    assert decoded["tool_permissions"]["modify_file"] == "allow"
    assert decoded["tool_permissions"]["web_get"] == "deny"

    updated = ProjectPolicy.add_deny_path(policy, "tmp/**")
    assert {:ok, saved} = ProjectPolicy.save(updated)
    assert "tmp/**" in saved.deny_paths
  end

  test "invalid JSON fails closed without crashing" do
    write_policy!("not json")

    policy = ProjectPolicy.load()

    assert policy.loaded?
    refute policy.valid?
    assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "lib/a.ex")
    assert message =~ "invalid JSON"
    assert [] == ToolPolicy.allowed_tool_names(ToolPolicy.default())
  end

  test "deny paths block exact, wildcard, and directory glob reads" do
    write_policy!(%{
      version: 1,
      deny_paths: [".env", ".env.*", "secrets/**"]
    })

    policy = ProjectPolicy.load()

    assert {:error, message} = ProjectPolicy.allowed_read_path?(policy, ".env")
    assert message =~ "deny_paths"
    assert {:error, _message} = ProjectPolicy.allowed_read_path?(policy, ".env.local")
    assert {:error, _message} = ProjectPolicy.allowed_read_path?(policy, "secrets/token.txt")
    assert :ok == ProjectPolicy.allowed_read_path?(policy, "lib/agent.ex")
  end

  test "read-only paths allow reads and block writes" do
    write_policy!(%{version: 1, read_only_paths: ["mix.lock", "config/prod.exs"]})

    policy = ProjectPolicy.load()

    assert :ok == ProjectPolicy.allowed_read_path?(policy, "mix.lock")
    assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "mix.lock")
    assert message =~ "read-only"
  end

  test "pure transformations add and remove path and tool permissions" do
    policy =
      ProjectPolicy.default()
      |> ProjectPolicy.add_deny_path("secrets/**")
      |> ProjectPolicy.add_read_only_path("mix.lock")
      |> ProjectPolicy.add_allow_write_path("lib/**")
      |> ProjectPolicy.set_tool_permission("web_get", "deny")

    assert "secrets/**" in policy.deny_paths
    assert "mix.lock" in policy.read_only_paths
    assert "lib/**" in policy.allow_write_paths
    assert policy.tool_permissions["web_get"] == "deny"

    policy =
      policy
      |> ProjectPolicy.remove_deny_path("secrets/**")
      |> ProjectPolicy.remove_read_only_path("mix.lock")
      |> ProjectPolicy.remove_allow_write_path("lib/**")
      |> ProjectPolicy.remove_tool_permission("web_get")

    refute "secrets/**" in policy.deny_paths
    refute "mix.lock" in policy.read_only_paths
    refute "lib/**" in policy.allow_write_paths
    refute Map.has_key?(policy.tool_permissions, "web_get")
  end

  test "weakening change detection identifies loosened policy" do
    old =
      ProjectPolicy.default()
      |> ProjectPolicy.add_deny_path("secrets/**")
      |> ProjectPolicy.add_read_only_path("mix.lock")
      |> ProjectPolicy.add_allow_write_path("lib/**")
      |> ProjectPolicy.set_tool_permission("web_get", "deny")

    assert ProjectPolicy.weakening_change?(old, ProjectPolicy.remove_deny_path(old, "secrets/**"))

    assert ProjectPolicy.weakening_change?(
             old,
             ProjectPolicy.remove_read_only_path(old, "mix.lock")
           )

    assert ProjectPolicy.weakening_change?(
             old,
             ProjectPolicy.add_allow_write_path(old, "test/**")
           )

    assert ProjectPolicy.weakening_change?(
             old,
             ProjectPolicy.set_tool_permission(old, "web_get", "allow")
           )

    refute ProjectPolicy.weakening_change?(
             old,
             ProjectPolicy.set_tool_permission(old, "mix", "deny")
           )
  end

  test "allow_write_paths restricts mutation locations" do
    write_policy!(%{version: 1, allow_write_paths: ["lib/**", "generated/**"]})

    policy = ProjectPolicy.load()

    assert :ok == ProjectPolicy.allowed_write_path?(policy, "lib/a.ex")
    assert :ok == ProjectPolicy.allowed_write_path?(policy, "generated/diagram.png")
    assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "scratch/a.ex")
    assert message =~ "outside allow_write_paths"
  end

  test "path traversal cannot bypass project policy" do
    write_policy!(%{version: 1, deny_paths: ["secrets/**"]})

    policy = ProjectPolicy.load()

    assert {:error, message} =
             ProjectPolicy.allowed_read_path?(policy, "secrets/../secrets/token")

    assert message =~ "path traversal is not allowed"
  end

  test "denied tools are hidden and blocked at execution" do
    write_policy!(%{version: 1, tool_permissions: %{task: "deny", web_get: "deny"}})

    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - task
      - web_get
      - read
      """)

    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    refute "task" in names
    refute "web_get" in names
    assert "read" in names

    assert Dispatcher.execute("task", %{"name" => "x", "prompt" => "do it"}, policy) =~
             "project policy"
  end

  test "legacy confirm tool permission requires restricted_write for mutation tools" do
    write_policy!(%{
      version: 1,
      allow_write_paths: ["lib/**"],
      tool_permissions: %{modify_file: "confirm", read: "allow"}
    })

    development =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - modify_file
      - read
      """)

    refute "modify_file" in ToolPolicy.allowed_tool_names(development)
    assert "read" in ToolPolicy.allowed_tool_names(development)

    confirmed = ToolPolicy.restricted_write_policy(["lib/a.ex"], ["modify_file", "read"])

    assert "modify_file" in ToolPolicy.allowed_tool_names(confirmed)
    assert :ok == ToolPolicy.allow_tool_call(confirmed, "modify_file", %{"path" => "lib/a.ex"})
  end

  test "dispatcher blocks denied paths even when direct execution is attempted" do
    write_policy!(%{version: 1, deny_paths: [".env"], allow_write_paths: ["**"]})

    policy = ToolPolicy.yolo()

    assert Dispatcher.execute("modify_file", %{"path" => ".env", "content" => "secret"}, policy) =~
             "project policy"

    refute File.exists?(".env")
  end

  test "freedom mode bypasses project policy but not hard path safety" do
    write_policy!(%{version: 1, deny_paths: ["scratch/**"], tool_permissions: %{web_get: "deny"}})

    normal_policy = ToolPolicy.yolo()
    freedom_policy = ToolPolicy.yolo(project_policy_bypassed?: true)
    normal_names = Dispatcher.tool_specs(normal_policy) |> Enum.map(& &1.function.name)
    freedom_names = Dispatcher.tool_specs(freedom_policy) |> Enum.map(& &1.function.name)

    refute "web_get" in normal_names
    assert "web_get" in freedom_names

    assert Dispatcher.execute(
             "modify_file",
             %{"path" => "scratch/freedom.ex", "content" => "ok"},
             normal_policy
           ) =~ "project policy"

    assert Dispatcher.execute(
             "modify_file",
             %{"path" => "scratch/freedom.ex", "content" => "ok"},
             freedom_policy
           ) =~ "Successfully wrote"

    assert File.read!("scratch/freedom.ex") == "ok"

    assert Dispatcher.execute(
             "modify_file",
             %{"path" => "../outside.ex", "content" => "bad"},
             freedom_policy
           ) =~ "path traversal is not allowed"
  end

  test "freedom mode bypass is scoped to the wrapped tool execution only" do
    write_policy!(%{version: 1, deny_paths: ["scratch/**"]})

    freedom_policy = ToolPolicy.yolo(project_policy_bypassed?: true)

    assert Dispatcher.execute(
             "modify_file",
             %{"path" => "scratch/scoped.ex", "content" => "ok"},
             freedom_policy
           ) =~ "Successfully wrote"

    policy = ProjectPolicy.load()
    assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "scratch/blocked.ex")
    assert message =~ "deny_paths"
  end

  test "normal mutation tools cannot edit project policy file" do
    File.mkdir_p!(".beamcore")
    File.write!(".beamcore/policy.json", "{}")
    File.write!("old.txt", "old")

    assert Modify.execute(%{"path" => ".beamcore/policy.json", "content" => "{}"}) =~
             "Project policy can only be changed"

    assert Modify.execute(%{
             "path" => ".beamcore/policy.json",
             "edits" => [%{"search" => "{}", "replace" => "{\"deny_paths\":[]}"}]
           }) =~ "Project policy can only be changed"

    assert Fs.execute(%{"operation" => "touch", "path" => ".beamcore/policy.json"}) =~
             "Project policy can only be changed"
  end

  test "image generation output path is checked before provider execution" do
    write_policy!(%{version: 1, read_only_paths: ["generated/locked.png"]})

    policy =
      ToolPolicy.restricted_write_policy(["generated/locked.png"], ["image_generation"])

    assert {:error, message} =
             ToolPolicy.allow_tool_call(policy, "image_generation", %{
               "prompt" => "draw",
               "output_path" => "generated/locked.png"
             })

    assert message =~ "read-only"
  end

  test "read directory, grep, glob, and tree hide denied paths" do
    File.mkdir_p!("secrets")
    File.write!("secrets/token.txt", "needle secret")
    File.mkdir_p!("lib")
    File.write!("lib/visible.ex", "needle visible")

    write_policy!(%{version: 1, deny_paths: ["secrets/**"]})

    read_output = Read.execute(%{"path" => "."})
    grep_output = Grep.execute(%{"pattern" => "needle", "path" => ".", "all" => true})
    glob_output = Glob.execute(%{"pattern" => "**/*.txt", "path" => ".", "all" => true})
    tree_output = Tree.execute(%{"path" => ".", "all" => true})

    refute read_output =~ "secrets"
    refute grep_output =~ "secrets/token.txt"
    refute glob_output =~ "secrets/token.txt"
    refute tree_output =~ "secrets"
    assert grep_output =~ "lib/visible.ex"
  end

  test "project policy can deny ecosystem command tools" do
    tools = ~w(python node make go rust terraform ruby bazel)

    for tool <- tools do
      write_policy!(%{version: 1, tool_permissions: %{tool => "deny"}})

      policy = ToolPolicy.default()
      names = Dispatcher.tool_specs(policy) |> Enum.map(& &1.function.name)

      refute tool in names

      assert Dispatcher.execute(tool, %{"command" => "test"}, policy) =~
               "Tool call blocked by project policy: #{tool}."
    end
  end

  defp write_policy!(data) when is_map(data), do: write_policy!(Jason.encode!(data))

  defp write_policy!(content) do
    File.mkdir_p!(".beamcore")
    File.write!(".beamcore/policy.json", content)
  end

  defp previous_repo_root do
    Path.expand("../../..", __DIR__)
  end
end
