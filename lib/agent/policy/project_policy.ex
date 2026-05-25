defmodule Beamcore.Agent.Policy.ProjectPolicy do
  @moduledoc """
  Optional project-local policy loaded from `.beamcore/policy.json`.

  This layer is intentionally stricter-only. Missing config preserves the
  existing runtime behavior; present config can deny tools or paths, but cannot
  bypass hard path safety, tool policy, or workspace bounds.
  """

  alias Beamcore.Agent.Tools.PathSafety

  @config_path ".beamcore/policy.json"
  @example_path ".beamcore/policy.example.json"
  @protected_paths [@config_path]
  @known_tools ~w(read grep glob edit patch write web_get tree git fs task mix plan image_generation)
  @write_tools ~w(write edit patch fs image_generation)
  @read_tools ~w(read grep glob tree)

  defstruct loaded?: false,
            valid?: true,
            path: nil,
            error: nil,
            deny_paths: [],
            read_only_paths: [],
            allow_write_paths: nil,
            tool_permissions: %{}

  @type t :: %__MODULE__{}

  @doc """
  Load optional project policy from the workspace root.
  """
  @spec load(binary() | nil) :: t()
  def load(root \\ nil) do
    root = root || PathSafety.workspace_root()
    path = Path.join(root, @config_path)

    if File.exists?(path) do
      path
      |> File.read()
      |> parse(path)
    else
      %__MODULE__{path: path}
    end
  end

  def config_path, do: @config_path
  def example_path, do: @example_path
  def known_tools, do: @known_tools
  def permissions, do: ~w(allow confirm deny)

  def default(root \\ nil) do
    root = root || PathSafety.workspace_root()
    %__MODULE__{path: Path.join(root, @config_path)}
  end

  def to_config(%__MODULE__{} = policy) do
    config = %{
      "version" => 1,
      "deny_paths" => policy.deny_paths,
      "read_only_paths" => policy.read_only_paths,
      "tool_permissions" => policy.tool_permissions
    }

    if is_list(policy.allow_write_paths) do
      Map.put(config, "allow_write_paths", policy.allow_write_paths)
    else
      config
    end
  end

  def show(%__MODULE__{} = policy) do
    policy
    |> to_config()
    |> Jason.encode!(pretty: true)
  end

  def save(%__MODULE__{} = policy), do: save(nil, policy)

  def save(root, %__MODULE__{} = policy) do
    root = root || PathSafety.workspace_root()
    path = Path.join(root, @config_path)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, show(%{policy | loaded?: true, valid?: true, path: path})) do
      {:ok, load(root)}
    end
  end

  def init(root \\ nil) do
    root = root || PathSafety.workspace_root()
    target = Path.join(root, @config_path)

    if File.exists?(target) do
      {:error, "Project policy already exists: #{@config_path}"}
    else
      policy = example_policy(root)
      save(root, policy)
    end
  end

  def add_deny_path(policy, pattern), do: update_list(policy, :deny_paths, pattern, :add)
  def remove_deny_path(policy, pattern), do: update_list(policy, :deny_paths, pattern, :remove)

  def add_read_only_path(policy, pattern),
    do: update_list(policy, :read_only_paths, pattern, :add)

  def remove_read_only_path(policy, pattern),
    do: update_list(policy, :read_only_paths, pattern, :remove)

  def add_allow_write_path(%__MODULE__{allow_write_paths: nil} = policy, pattern),
    do: update_list(%{policy | allow_write_paths: []}, :allow_write_paths, pattern, :add)

  def add_allow_write_path(policy, pattern),
    do: update_list(policy, :allow_write_paths, pattern, :add)

  def remove_allow_write_path(policy, pattern),
    do: update_list(policy, :allow_write_paths, pattern, :remove)

  def set_tool_permission(%__MODULE__{} = policy, tool, permission)
      when tool in @known_tools and permission in ["allow", "confirm", "deny"] do
    %{policy | tool_permissions: Map.put(policy.tool_permissions, tool, permission)}
  end

  def remove_tool_permission(%__MODULE__{} = policy, tool) when tool in @known_tools do
    %{policy | tool_permissions: Map.delete(policy.tool_permissions, tool)}
  end

  def weakening_change?(%__MODULE__{} = old, %__MODULE__{} = new) do
    removes_restrictions?(old.deny_paths, new.deny_paths) or
      removes_restrictions?(old.read_only_paths, new.read_only_paths) or
      expands_allow_write?(old.allow_write_paths, new.allow_write_paths) or
      weakens_tools?(old.tool_permissions, new.tool_permissions)
  end

  @doc """
  Filter already-authorized tool names through project-level permissions.
  """
  def allowed_tool_names(tool_names, runtime_policy, %__MODULE__{} = project_policy) do
    if fail_closed?(project_policy) do
      []
    else
      Enum.filter(tool_names, &tool_exposed?(&1, runtime_policy, project_policy))
    end
  end

  @doc """
  Authorize a concrete tool call against project policy.
  """
  def allow_tool_call(%__MODULE__{} = project_policy, runtime_policy, name, args)
      when is_binary(name) and is_map(args) do
    cond do
      not project_policy.loaded? ->
        :ok

      fail_closed?(project_policy) ->
        {:error, invalid_config_message(project_policy)}

      not tool_exposed?(name, runtime_policy, project_policy) ->
        {:error, "Tool call blocked by project policy: #{name}."}

      true ->
        allow_tool_paths(project_policy, name, args)
    end
  end

  def allow_tool_call(%__MODULE__{} = project_policy, runtime_policy, name, _args) do
    allow_tool_call(project_policy, runtime_policy, name, %{})
  end

  def allowed_read_path?(%__MODULE__{} = project_policy, path) do
    cond do
      fail_closed?(project_policy) ->
        {:error, invalid_config_message(project_policy)}

      true ->
        with {:ok, relative} <- normalize_path(path) do
          allow_read_relative(project_policy, relative)
        end
    end
  end

  def allowed_read_path?(path), do: load() |> allowed_read_path?(path)

  def allowed_write_path?(%__MODULE__{} = project_policy, path) do
    cond do
      fail_closed?(project_policy) ->
        {:error, invalid_config_message(project_policy)}

      protected_policy_path?(path) ->
        {:error, "Project policy can only be changed through explicit /policy commands."}

      true ->
        with {:ok, relative} <- normalize_path(path, allow_missing: true) do
          allow_write_relative(project_policy, relative)
        end
    end
  end

  def allowed_write_path?(path), do: load() |> allowed_write_path?(path)

  def denied_path?(%__MODULE__{} = project_policy, path) do
    with {:ok, relative} <- normalize_path(path, allow_missing: true) do
      matches_any?(relative, project_policy.deny_paths)
    else
      {:error, _reason} -> true
    end
  end

  def denied_path?(path), do: load() |> denied_path?(path)

  def ignored?(file, _root_path) do
    policy = load()
    policy.loaded? and (not policy.valid? or denied_path?(policy, file))
  end

  def explain_block({:error, reason}), do: reason
  def explain_block(:ok), do: "allowed"

  def summary(%__MODULE__{loaded?: false, path: path}) do
    "Project policy: not loaded (#{Path.relative_to(path, PathSafety.workspace_root())})."
  end

  def summary(%__MODULE__{valid?: false, error: error, path: path}) do
    "Project policy: invalid #{Path.relative_to(path, PathSafety.workspace_root())}: #{error}."
  end

  def summary(%__MODULE__{} = policy) do
    [
      "Project policy: loaded #{Path.relative_to(policy.path, PathSafety.workspace_root())}.",
      count_line("deny paths", policy.deny_paths),
      count_line("read-only paths", policy.read_only_paths),
      count_line("write allowlist", policy.allow_write_paths || []),
      count_line("tool permissions", Map.keys(policy.tool_permissions))
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp parse({:ok, content}, path) do
    case Jason.decode(content) do
      {:ok, decoded} when is_map(decoded) ->
        build(decoded, path)

      {:ok, _other} ->
        invalid(path, "policy JSON must be an object")

      {:error, error} ->
        invalid(path, "invalid JSON: #{Exception.message(error)}")
    end
  end

  defp parse({:error, reason}, path), do: invalid(path, "cannot read policy: #{reason}")

  defp build(data, path) do
    %__MODULE__{
      loaded?: true,
      valid?: true,
      path: path,
      deny_paths: list(data["deny_paths"]),
      read_only_paths: list(data["read_only_paths"]),
      allow_write_paths: optional_list(data["allow_write_paths"]),
      tool_permissions: tool_permissions(data["tool_permissions"])
    }
  end

  defp invalid(path, message) do
    %__MODULE__{loaded?: true, valid?: false, path: path, error: message}
  end

  defp fail_closed?(%__MODULE__{loaded?: true, valid?: false}), do: true
  defp fail_closed?(_policy), do: false

  defp tool_exposed?(_name, _runtime_policy, %__MODULE__{loaded?: false}), do: true

  defp tool_exposed?(name, runtime_policy, %__MODULE__{} = project_policy) do
    case Map.get(project_policy.tool_permissions, name, "allow") do
      "allow" -> true
      "deny" -> false
      "confirm" -> confirm_satisfied?(name, runtime_policy)
      _unknown -> false
    end
  end

  defp confirm_satisfied?(name, %{mode: :restricted_write}) when name in @write_tools, do: true
  defp confirm_satisfied?(name, _runtime_policy) when name in @write_tools, do: false
  defp confirm_satisfied?(_name, _runtime_policy), do: true

  defp allow_tool_paths(policy, name, args) when name in @read_tools do
    args
    |> path_values(["filePath", "path"])
    |> allow_all(policy, :read)
  end

  defp allow_tool_paths(policy, "write", args),
    do: args |> path_values(["filePath", "path"]) |> allow_all(policy, :write)

  defp allow_tool_paths(policy, "edit", args),
    do: args |> path_values(["path"]) |> allow_all(policy, :write)

  defp allow_tool_paths(policy, "image_generation", args),
    do: args |> path_values(["output_path"]) |> allow_all(policy, :write)

  defp allow_tool_paths(policy, "patch", args) do
    args
    |> Map.get("patch_content", "")
    |> patch_paths()
    |> allow_all(policy, :write)
  end

  defp allow_tool_paths(policy, "plan", args) do
    args
    |> plan_paths()
    |> allow_all(policy, :write)
  end

  defp allow_tool_paths(policy, "fs", %{"operation" => operation} = args) do
    case operation do
      "stat" -> args |> path_values(["path"]) |> allow_all(policy, :read)
      "exist" -> args |> path_values(["path"]) |> allow_all(policy, :read)
      "copy" -> allow_copy(policy, args)
      "move" -> allow_move(policy, args)
      "remove" -> args |> path_values(["path"]) |> allow_all(policy, :write)
      "touch" -> args |> path_values(["path"]) |> allow_all(policy, :write)
      "mkdir" -> args |> path_values(["path"]) |> allow_all(policy, :write)
      _ -> :ok
    end
  end

  defp allow_tool_paths(policy, "git", args) do
    args
    |> path_values(["path", "workdir"])
    |> allow_all(policy, :read)
  end

  defp allow_tool_paths(_policy, _name, _args), do: :ok

  defp allow_copy(policy, args) do
    with :ok <- args |> path_values(["path"]) |> allow_all(policy, :read) do
      args |> path_values(["target"]) |> allow_all(policy, :write)
    end
  end

  defp allow_move(policy, args) do
    with :ok <- args |> path_values(["path"]) |> allow_all(policy, :write) do
      args |> path_values(["target"]) |> allow_all(policy, :write)
    end
  end

  defp allow_all(paths, policy, mode) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      result =
        case mode do
          :read -> allowed_read_path?(policy, path)
          :write -> allowed_write_path?(policy, path)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp allow_read_relative(%__MODULE__{} = policy, relative) do
    if matches_any?(relative, policy.deny_paths) do
      {:error, "Path blocked by project policy: #{relative} matches deny_paths."}
    else
      :ok
    end
  end

  defp allow_write_relative(%__MODULE__{} = policy, relative) do
    cond do
      matches_any?(relative, policy.deny_paths) ->
        {:error, "Path blocked by project policy: #{relative} matches deny_paths."}

      matches_any?(relative, policy.read_only_paths) ->
        {:error, "Path blocked by project policy: #{relative} is read-only."}

      is_list(policy.allow_write_paths) and not matches_any?(relative, policy.allow_write_paths) ->
        {:error, "Path blocked by project policy: #{relative} is outside allow_write_paths."}

      true ->
        :ok
    end
  end

  defp normalize_path(path, opts \\ []) do
    path
    |> to_string()
    |> PathSafety.resolve(opts)
    |> case do
      {:ok, absolute} -> {:ok, Path.relative_to(absolute, PathSafety.workspace_root())}
      {:error, reason} -> {:error, reason}
    end
  end

  defp path_values(args, keys) do
    keys
    |> Enum.map(&Map.get(args, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp patch_paths(patch) when is_binary(patch) do
    patch
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ")))
    |> Enum.map(&patch_line_path/1)
    |> Enum.reject(&(&1 in [nil, "/dev/null"]))
    |> Enum.map(&strip_patch_prefix/1)
    |> Enum.uniq()
  end

  defp patch_paths(_patch), do: []

  defp plan_paths(args) do
    ["create_files", "modify_files", "delete_files"]
    |> Enum.flat_map(&(Map.get(args, &1, []) |> List.wrap()))
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp matches_any?(relative, patterns), do: Enum.any?(patterns, &match_pattern?(relative, &1))

  defp match_pattern?(relative, pattern) do
    pattern = pattern |> to_string() |> String.trim_leading("/")

    cond do
      pattern == relative ->
        true

      String.ends_with?(pattern, "/**") ->
        prefix = String.trim_trailing(pattern, "/**")
        relative == prefix or String.starts_with?(relative, prefix <> "/")

      String.contains?(pattern, "*") or String.contains?(pattern, "?") ->
        pattern
        |> Regex.escape()
        |> String.replace("\\*\\*", ".*")
        |> String.replace("\\*", "[^/]*")
        |> String.replace("\\?", ".")
        |> then(&Regex.compile("^" <> &1 <> "$"))
        |> case do
          {:ok, regex} -> Regex.match?(regex, relative)
          {:error, _} -> false
        end

      true ->
        false
    end
  end

  defp tool_permissions(nil), do: %{}

  defp tool_permissions(values) when is_map(values) do
    values
    |> Enum.filter(fn {tool, value} ->
      tool in @known_tools and value in ["allow", "confirm", "deny"]
    end)
    |> Map.new()
  end

  defp tool_permissions(_values), do: %{}

  defp optional_list(nil), do: nil
  defp optional_list(values), do: list(values)

  defp list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_pattern/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp list(_values), do: []

  defp normalize_pattern(pattern) do
    pattern
    |> String.trim()
    |> String.trim_leading("/")
  end

  defp update_list(%__MODULE__{} = policy, field, pattern, :add) do
    pattern = normalize_pattern(pattern)
    values = policy |> Map.get(field) |> List.wrap()
    Map.put(policy, field, Enum.uniq(values ++ [pattern]))
  end

  defp update_list(%__MODULE__{} = policy, field, pattern, :remove) do
    pattern = normalize_pattern(pattern)
    values = policy |> Map.get(field) |> List.wrap()
    Map.put(policy, field, Enum.reject(values, &(&1 == pattern)))
  end

  defp removes_restrictions?(old_values, new_values) do
    old = MapSet.new(old_values || [])
    new = MapSet.new(new_values || [])
    not MapSet.subset?(old, new)
  end

  defp expands_allow_write?(nil, _new), do: false
  defp expands_allow_write?(_old, nil), do: true

  defp expands_allow_write?(old_values, new_values) do
    old = MapSet.new(old_values || [])
    new = MapSet.new(new_values || [])
    not MapSet.subset?(new, old)
  end

  defp weakens_tools?(old_permissions, new_permissions) do
    @known_tools
    |> Enum.any?(fn tool ->
      permission_rank(Map.get(new_permissions, tool, "allow")) >
        permission_rank(Map.get(old_permissions, tool, "allow"))
    end)
  end

  defp permission_rank("deny"), do: 0
  defp permission_rank("confirm"), do: 1
  defp permission_rank("allow"), do: 2
  defp permission_rank(_), do: 2

  defp protected_policy_path?(path) do
    case normalize_path(path, allow_missing: true) do
      {:ok, relative} -> relative in @protected_paths
      {:error, _reason} -> false
    end
  end

  defp example_policy(root) do
    example_file = Path.join(root, @example_path)

    if File.exists?(example_file) do
      load_from_file(example_file)
    else
      build(example_config(), Path.join(root, @config_path))
    end
  end

  defp load_from_file(path) do
    case path |> File.read() |> parse(path) do
      %__MODULE__{valid?: true} = policy -> policy
      _invalid -> build(example_config(), path)
    end
  end

  defp example_config do
    %{
      "version" => 1,
      "deny_paths" => [
        ".env",
        ".env.*",
        "secrets/**",
        "private/**",
        "_build/**",
        "deps/**",
        ".git/**"
      ],
      "read_only_paths" => ["mix.lock", "config/prod.exs"],
      "allow_write_paths" => ["lib/**", "test/**", "README.md", "generated/**"],
      "tool_permissions" => %{
        "read" => "allow",
        "grep" => "allow",
        "glob" => "allow",
        "tree" => "allow",
        "write" => "allow",
        "edit" => "allow",
        "patch" => "allow",
        "fs" => "allow",
        "git" => "allow",
        "mix" => "allow",
        "image_generation" => "allow",
        "task" => "deny",
        "web_get" => "deny"
      }
    }
  end

  defp patch_line_path(line) do
    line
    |> String.split(~r/\s+/, parts: 3, trim: true)
    |> Enum.at(1)
  end

  defp strip_patch_prefix("a/" <> path), do: path
  defp strip_patch_prefix("b/" <> path), do: path
  defp strip_patch_prefix(path), do: path

  defp count_line(_label, []), do: nil
  defp count_line(label, values), do: "#{length(values)} #{label}."

  defp invalid_config_message(policy), do: "Project policy config is invalid: #{policy.error}."
end
