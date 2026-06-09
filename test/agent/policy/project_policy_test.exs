defmodule Beamcore.Agent.Policy.ProjectPolicyTest do
  use ExUnit.Case

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.Policy.ProjectPolicy
  alias Beamcore.Agent.Tools.{Dispatcher, Grep, Modify}

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
    assert decoded["tool_permissions"]["task"] == "deny"

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
      |> ProjectPolicy.set_tool_permission("task", "deny")

    assert "secrets/**" in policy.deny_paths
    assert "mix.lock" in policy.read_only_paths
    assert "lib/**" in policy.allow_write_paths
    assert policy.tool_permissions["task"] == "deny"

    policy =
      policy
      |> ProjectPolicy.remove_deny_path("secrets/**")
      |> ProjectPolicy.remove_read_only_path("mix.lock")
      |> ProjectPolicy.remove_allow_write_path("lib/**")
      |> ProjectPolicy.remove_tool_permission("task")

    refute "secrets/**" in policy.deny_paths
    refute "mix.lock" in policy.read_only_paths
    refute "lib/**" in policy.allow_write_paths
    refute Map.has_key?(policy.tool_permissions, "task")
  end

  test "weakening change detection identifies loosened policy" do
    old =
      ProjectPolicy.default()
      |> ProjectPolicy.add_deny_path("secrets/**")
      |> ProjectPolicy.add_read_only_path("mix.lock")
      |> ProjectPolicy.add_allow_write_path("lib/**")
      |> ProjectPolicy.set_tool_permission("task", "deny")

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
             ProjectPolicy.set_tool_permission(old, "task", "allow")
           )

    refute ProjectPolicy.weakening_change?(
             old,
             ProjectPolicy.set_tool_permission(old, "test_tool", "deny")
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
    write_policy!(%{version: 1, tool_permissions: %{task: "deny", git: "deny"}})

    policy =
      ToolPolicy.from_user_message("""
      Policy:
      mode: development
      allowed_tools:
      - task
      - git
      - eeva
      """)

    names = Dispatcher.tool_specs(policy) |> Enum.map(fn spec -> spec.function.name end)

    refute "task" in names
    refute "git" in names
    assert "eeva" in names

    assert Dispatcher.execute("task", %{"name" => "x", "prompt" => "do it"}, policy) =~
             "project policy"
  end

  test "confirm tool permission allows normal autonomous coding within project policy paths" do
    write_policy!(%{
      version: 1,
      allow_write_paths: ["src/**"],
      tool_permissions: %{modify_file: "confirm", git: "confirm", eeva: "allow"}
    })

    normal = ToolPolicy.default()

    assert "modify_file" in ToolPolicy.allowed_tool_names(normal)
    assert "git" in ToolPolicy.allowed_tool_names(normal)
    assert "eeva" in ToolPolicy.allowed_tool_names(normal)

    assert :ok ==
             ToolPolicy.allow_tool_call(normal, "modify_file", %{
               "operation" => "create_file",
               "path" => "src/algorithms/sort.ex",
               "content" => "ok"
             })

    assert :ok ==
             ToolPolicy.allow_tool_call(normal, "git", %{
               "operation" => "status"
             })

    assert {:error, message} =
             ToolPolicy.allow_tool_call(normal, "modify_file", %{
               "operation" => "create_file",
               "path" => "scratch/outside.ex",
               "content" => "blocked"
             })

    assert message =~ "outside allow_write_paths"
  end

  test "confirm tool permission still blocks mutation tools in read-only mode" do
    write_policy!(%{
      version: 1,
      allow_write_paths: ["src/**"],
      tool_permissions: %{modify_file: "confirm", image_generation: "confirm", eeva: "allow"}
    })

    read_only =
      ToolPolicy.from_user_message("""
      Policy:
      mode: read_only
      allowed_tools:
      - modify_file
      - image_generation
      - eeva
      """)

    refute "modify_file" in ToolPolicy.allowed_tool_names(read_only)
    refute "image_generation" in ToolPolicy.allowed_tool_names(read_only)
    assert "eeva" in ToolPolicy.allowed_tool_names(read_only)

    assert {:error, message} =
             ToolPolicy.allow_tool_call(read_only, "image_generation", %{
               "output_path" => "src/datastructures/diagram.png"
             })

    assert message =~ "read-only policy"
  end

  test "dispatcher blocks denied paths even when direct execution is attempted" do
    write_policy!(%{version: 1, deny_paths: [".env"], allow_write_paths: ["**"]})

    policy = ToolPolicy.yolo()

    assert Dispatcher.execute(
             "modify_file",
             %{"operation" => "create_file", "path" => ".env", "content" => "secret"},
             policy
           ) =~
             "project policy"

    refute File.exists?(".env")
  end

  test "freedom mode bypasses project policy but not hard path safety" do
    write_policy!(%{version: 1, deny_paths: ["scratch/**"], tool_permissions: %{task: "deny"}})

    normal_policy = ToolPolicy.yolo()
    freedom_policy = ToolPolicy.yolo(project_policy_bypassed?: true)
    normal_names = Dispatcher.tool_specs(normal_policy) |> Enum.map(& &1.function.name)
    freedom_names = Dispatcher.tool_specs(freedom_policy) |> Enum.map(& &1.function.name)

    refute "task" in normal_names
    assert "task" in freedom_names

    assert Dispatcher.execute(
             "modify_file",
             %{"operation" => "create_file", "path" => "scratch/freedom.ex", "content" => "ok"},
             normal_policy
           ) =~ "project policy"

    result =
      Dispatcher.execute(
        "modify_file",
        %{"operation" => "create_file", "path" => "scratch/freedom.ex", "content" => "ok"},
        freedom_policy
      )

    assert Jason.decode!(result)["ok"]

    assert File.read!("scratch/freedom.ex") == "ok"

    assert Dispatcher.execute(
             "modify_file",
             %{"operation" => "create_file", "path" => "../outside.ex", "content" => "bad"},
             freedom_policy
           ) =~ "path traversal is not allowed"
  end

  test "freedom mode bypass is scoped to the wrapped tool execution only" do
    write_policy!(%{version: 1, deny_paths: ["scratch/**"]})

    freedom_policy = ToolPolicy.yolo(project_policy_bypassed?: true)

    result =
      Dispatcher.execute(
        "modify_file",
        %{"operation" => "create_file", "path" => "scratch/scoped.ex", "content" => "ok"},
        freedom_policy
      )

    assert Jason.decode!(result)["ok"]

    policy = ProjectPolicy.load()
    assert {:error, message} = ProjectPolicy.allowed_write_path?(policy, "scratch/blocked.ex")
    assert message =~ "deny_paths"
  end

  test "normal mutation tools cannot edit project policy file" do
    File.mkdir_p!(".beamcore")
    File.write!(".beamcore/policy.json", "{}")
    File.write!("old.txt", "old")

    assert Modify.execute(%{
             "operation" => "create_file",
             "path" => ".beamcore/policy.json",
             "content" => "{}",
             "overwrite" => true
           }) =~
             "Project policy can only be changed"

    assert Modify.execute(%{
             "operation" => "replace_exact",
             "path" => ".beamcore/policy.json",
             "old" => "{}",
             "new" => "{\"deny_paths\":[]}"
           }) =~ "Project policy can only be changed"
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

  test "grep hides denied paths" do
    File.mkdir_p!("secrets")
    File.write!("secrets/token.txt", "needle secret")
    File.mkdir_p!("lib")
    File.write!("lib/visible.ex", "needle visible")

    write_policy!(%{version: 1, deny_paths: ["secrets/**"]})

    grep_output = Grep.execute(%{"pattern" => "needle", "path" => ".", "all" => true})

    refute grep_output =~ "secrets/token.txt"
    assert grep_output =~ "lib/visible.ex"
  end

  test "project policy can deny test_tool" do
    tool = "test_tool"
    write_policy!(%{version: 1, tool_permissions: %{tool => "deny"}})

    policy = ToolPolicy.default()
    names = Dispatcher.tool_specs(policy) |> Enum.map(& &1.function.name)

    refute tool in names

    assert Dispatcher.execute(tool, %{"args" => "test"}, policy) =~
             "Tool call blocked by project policy: #{tool}."
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
