defmodule Beamcore.Agent.Tools.Eeva.Policy do
  @moduledoc false

  alias Beamcore.Agent.Chat.ToolPolicy
  alias Beamcore.Agent.FilesystemJournal
  alias Beamcore.Agent.PathSafety
  alias Beamcore.Agent.Policy.ProjectPolicy

  @process_key {__MODULE__, :runtime}

  @file_read_functions ~w(
    read read! ls ls! stream! stat stat! lstat lstat! exists? dir? regular?
    read_link read_link! open open! cwd cwd!
  )a

  @file_write_functions ~w(
    write write! mkdir mkdir! mkdir_p mkdir_p! rm rm! rm_rf rm_rf!
    cp cp! cp_r cp_r! rename rename! touch touch! chmod chmod! ln_s ln_s!
    open open!
  )a

  @blocked_modules [
    Agent,
    Application,
    Code,
    GenServer,
    Module,
    Port,
    Process,
    Registry,
    Supervisor,
    Task,
    Task.Supervisor,
    Beamcore.Agent.Chat.Session,
    Beamcore.Agent.Chat.ToolPolicy,
    Beamcore.Agent.FilesystemJournal,
    Beamcore.Agent.FilesystemJournal.Server,
    Beamcore.Agent.PathSafety,
    Beamcore.Agent.Policy.ProjectPolicy,
    Beamcore.Agent.RestoreCoordinator,
    Beamcore.Agent.Runtime,
    Beamcore.Agent.Timeline,
    Beamcore.Agent.Tools.Eeva.AtomBudget,
    Beamcore.Agent.Tools.Eeva.IODevice,
    Beamcore.Agent.Tools.Eeva.Supervisor,
    Beamcore.Agent.Tools.Eeva.Worker,
    :code,
    :dets,
    :erl_eval,
    :erlang,
    :ets,
    :file,
    :global,
    :os,
    :peer,
    :persistent_term,
    :rpc,
    :slave
  ]

  @blocked_model_runtime_modules [
    Beamcore.Agent.Chat.Session,
    Beamcore.Agent.Chat.ToolPolicy,
    Beamcore.Agent.FilesystemJournal,
    Beamcore.Agent.FilesystemJournal.Server,
    Beamcore.Agent.PathSafety,
    Beamcore.Agent.Policy.ProjectPolicy,
    Beamcore.Agent.RestoreCoordinator,
    Beamcore.Agent.Runtime,
    Beamcore.Agent.Timeline,
    Beamcore.Agent.Tools.Eeva.AtomBudget,
    Beamcore.Agent.Tools.Eeva.IODevice,
    Beamcore.Agent.Tools.Eeva.Supervisor,
    Beamcore.Agent.Tools.Eeva.Worker
  ]

  @blocked_system_functions ~w(
    at_exit build_info cmd_env delete_env fetch_env fetch_env! get_env get_pid halt
    no_halt? os_time put_env restart shell stop tmp_dir tmp_dir!
  )a

  @blocked_kernel_functions ~w(
    alias apply binary_to_atom binary_to_existing_atom binary_to_term def defdelegate
    defexception defguard defguardp defimpl defmacro defmacrop defmodule defoverridable
    defp defprotocol defstruct exit import list_to_atom list_to_existing_atom quote
    require send spawn spawn_link spawn_monitor unquote unquote_splicing use
  )a

  @memory_read_functions ~w(__info__ detect_org_repo recall list search types overview summary)a
  @memory_write_functions ~w(remember forget clear)a

  @network_commands ~w(curl wget nc ncat netcat ssh scp sftp rsync ftp telnet)
  @shell_commands ~w(sh bash zsh fish dash ksh csh tcsh cmd powershell pwsh osascript)
  @read_only_commands ~w(elixir erl mix git make cargo go npm pnpm yarn python python3 ruby java javac)

  @type runtime :: %{policy: map(), workspace_root: binary()}

  def prepare(quoted, policy) when is_map(policy) do
    with :ok <- validate(quoted, policy) do
      {:ok, instrument(quoted)}
    end
  end

  def install(policy, workspace_root) when is_map(policy) and is_binary(workspace_root) do
    Process.put(@process_key, %{policy: policy, workspace_root: PathSafety.canonical_path(workspace_root)})
    :ok
  end

  def clear do
    Process.delete(@process_key)
    :ok
  end

  def file(:cwd, []) do
    {:ok, runtime!().workspace_root}
  end

  def file(:cwd!, []) do
    runtime!().workspace_root
  end

  def file(function, args) when is_atom(function) and is_list(args) do
    runtime = runtime!()

    case classify_file_call(function, args) do
      {:read, transformed_args} ->
        transformed_args
        |> authorize_file_args(:read, runtime)
        |> call_file(function)

      {:write, transformed_args} ->
        transformed_args
        |> authorize_file_args(:write, runtime)
        |> call_tracked_file(function, runtime)

      {:mixed, transformed_args, read_indexes, write_indexes} ->
        transformed_args
        |> authorize_indexed_file_args(read_indexes, :read, runtime)
        |> authorize_indexed_file_args(write_indexes, :write, runtime)
        |> call_tracked_file(function, runtime)

      {:error, reason} ->
        raise ArgumentError, reason
    end
  end

  def wildcard(pattern, opts \\ []) when is_binary(pattern) and is_list(opts) do
    runtime = runtime!()

    with :ok <- PathSafety.validate_pattern(pattern),
         {:ok, absolute_pattern} <- resolve_pattern(pattern, runtime),
         matches <- Path.wildcard(absolute_pattern, opts) do
      matches
      |> Enum.reduce([], fn absolute, acc ->
        relative = Path.relative_to(absolute, runtime.workspace_root)

        case authorize_path(relative, :read, runtime) do
          {:ok, _absolute} -> [relative | acc]
          {:error, _reason} -> acc
        end
      end)
      |> Enum.reverse()
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def system_cmd(executable, args, opts \\ [])
      when is_binary(executable) and is_list(args) and is_list(opts) do
    runtime = runtime!()
    command = executable |> Path.basename() |> String.downcase()

    with :ok <- authorize_command(command, args, runtime),
         {:ok, safe_opts} <- command_options(opts, runtime) do
      System.cmd(executable, Enum.map(args, &to_string/1), safe_opts)
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def memory(function, args) when is_atom(function) and is_list(args) do
    runtime = runtime!()

    cond do
      function in @memory_read_functions ->
        apply(Beamcore.Memory, function, args)

      function in @memory_write_functions ->
        with :ok <- authorize_memory_write(runtime) do
          case apply(Beamcore.Memory, function, args) do
            {:error, reason} -> raise ArgumentError, "Memory mutation failed: #{inspect(reason)}"
            other -> other
          end
        else
          {:error, reason} -> raise ArgumentError, reason
        end

      true ->
        raise ArgumentError,
              "Beamcore.Memory.#{function}/#{length(args)} is not available inside Eeva."
    end
  end

  defp validate(quoted, policy) do
    {_quoted, errors} =
      Macro.prewalk(quoted, [], fn node, errors ->
        {node, validate_node(node, policy, errors)}
      end)

    case errors |> Enum.reverse() |> Enum.uniq() do
      [] -> :ok
      messages -> {:error, "Policy violation: " <> Enum.join(messages, " ")}
    end
  end

  defp validate_node({form, meta, args}, _policy, errors)
       when is_atom(form) and is_list(args) and form in @blocked_kernel_functions do
    ["#{form}/#{length(args)} is unavailable inside Eeva at line #{line(meta)}." | errors]
  end

  defp validate_node({:__aliases__, meta, parts}, _policy, errors) when is_list(parts) do
    module = Module.concat(parts)

    if module in @blocked_model_runtime_modules do
      ["References to #{inspect(module)} are unavailable inside Eeva at line #{line(meta)}." | errors]
    else
      errors
    end
  end

  defp validate_node(
         {:&, meta, [{:/, _slash_meta, [{{:., _dot_meta, [module_ast, function]}, _call_meta, []}, arity]}]},
         _policy,
         errors
       )
       when is_atom(function) and is_integer(arity) do
    module = module_from_ast(module_ast)

    if module in [File, Path, System, Beamcore.Memory] do
      [
        "Capturing #{inspect(module)}.#{function}/#{arity} would bypass Eeva policy instrumentation at line #{line(meta)}. Call it directly instead."
        | errors
      ]
    else
      errors
    end
  end

  defp validate_node({{:., meta, [module_ast, function]}, call_meta, args}, policy, errors)
       when is_atom(function) and is_list(args) do
    module = module_from_ast(module_ast)

    cond do
      module == Process and function == :sleep ->
        errors

      module in @blocked_modules ->
        ["Calls to #{inspect(module)} are unavailable inside Eeva at line #{line(meta)}." | errors]

      module == System and function in @blocked_system_functions ->
        ["System.#{function}/#{length(args)} is unavailable inside Eeva at line #{line(meta)}." | errors]

      module == File and function in [:cd, :cd!] ->
        ["File.#{function}/#{length(args)} is unavailable; Eeva already owns the workspace directory." | errors]

      network_module?(module) and not Map.get(policy, :allow_network, false) ->
        ["Network access through #{inspect(module)} is blocked by the active policy." | errors]

      direct_internal_policy_call?(module) ->
        ["Direct access to Eeva policy internals is unavailable." | errors]

      is_nil(module) and not (args == [] and Keyword.get(call_meta, :no_parens, false)) ->
        ["Dynamic module invocation is unavailable because it would bypass Eeva policy checks." | errors]

      true ->
        errors
    end
  end

  defp validate_node(_node, _policy, errors), do: errors

  defp instrument(quoted) do
    Macro.prewalk(quoted, fn
      {{:., dot_meta, [module_ast, function]}, call_meta, args} = node
      when is_atom(function) and is_list(args) ->
        case module_from_ast(module_ast) do
          File -> policy_call(:file, [function, args], dot_meta, call_meta)
          Path when function == :wildcard -> policy_call(:wildcard, args, dot_meta, call_meta)
          System when function == :cmd -> policy_call(:system_cmd, args, dot_meta, call_meta)
          Beamcore.Memory -> policy_call(:memory, [function, args], dot_meta, call_meta)
          _ -> node
        end

      node ->
        node
    end)
  end

  defp policy_call(function, args, dot_meta, call_meta) do
    {{:., dot_meta, [__MODULE__, function]}, call_meta, args}
  end

  defp classify_file_call(:cwd, args), do: {:read, args}
  defp classify_file_call(:cwd!, args), do: {:read, args}

  defp classify_file_call(function, args) when function in [:cp, :cp!, :cp_r, :cp_r!] do
    {:mixed, args, [0], [1]}
  end

  defp classify_file_call(function, args) when function in [:rename, :rename!] do
    {:mixed, args, [], [0, 1]}
  end

  defp classify_file_call(function, args) when function in [:ln_s, :ln_s!] do
    {:mixed, args, [0], [1]}
  end

  defp classify_file_call(function, args) when function in [:open, :open!, :stream!] do
    modes = Enum.at(args, 1, [])

    if write_modes?(modes) do
      {:error,
       "File.#{function} write modes are unavailable inside Eeva because streaming writes cannot be journaled precisely. Use File.write!/2 or File.write/3 instead."}
    else
      {:read, args}
    end
  end

  defp classify_file_call(function, args) when function in @file_read_functions,
    do: {:read, args}

  defp classify_file_call(function, args) when function in @file_write_functions,
    do: {:write, args}

  defp classify_file_call(function, _args),
    do: {:error, "File.#{function} is not supported inside the Eeva workspace boundary."}

  defp authorize_file_args([], _mode, _runtime), do: []
  defp authorize_file_args([path | rest], mode, runtime) do
    case authorize_path(path, mode, runtime) do
      {:ok, absolute} -> [absolute | rest]
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp authorize_indexed_file_args(args, indexes, mode, runtime) do
    Enum.reduce(indexes, args, fn index, current ->
      case Enum.fetch(current, index) do
        {:ok, path} ->
          case authorize_path(path, mode, runtime) do
            {:ok, absolute} -> List.replace_at(current, index, absolute)
            {:error, reason} -> raise ArgumentError, reason
          end

        :error ->
          current
      end
    end)
  end

  defp call_file(args, function), do: apply(File, function, args)

  defp call_tracked_file(args, function, runtime) when function in [:write, :write!] do
    [path | _rest] = args
    before_state = snapshot_before!(path, runtime)
    result = apply(File, function, args)

    if successful_file_result?(result) do
      after_bytes = read_after_bytes!(path)
      journal_or_raise(FilesystemJournal.record_file_write(path, before_state, after_bytes, tool: "eeva"))
    end

    result
  end

  defp call_tracked_file(args, function, runtime)
       when function in [:mkdir, :mkdir!, :mkdir_p, :mkdir_p!] do
    [path | _rest] = args
    before_state = snapshot_before!(path, runtime)

    missing_dirs =
      if function in [:mkdir_p, :mkdir_p!], do: missing_directory_chain(path, runtime), else: []

    result = apply(File, function, args)

    if successful_file_result?(result) do
      dirs =
        if missing_dirs == [] do
          if not state_exists?(before_state), do: [path], else: []
        else
          missing_dirs
        end

      Enum.each(dirs, fn dir ->
        journal_or_raise(FilesystemJournal.record_mkdir(dir, tool: "eeva"))
      end)
    end

    result
  end

  defp call_tracked_file(args, function, _runtime)
       when function in [:rm, :rm!, :rm_rf, :rm_rf!] do
    [path | _rest] = args
    prepared = prepare_remove(path)
    result = apply(File, function, args)

    if match?({:ok, _prepared}, prepared) and successful_file_result?(result) do
      {:ok, prepared} = prepared
      journal_or_raise(FilesystemJournal.commit_prepared(prepared))
    end

    result
  end

  defp call_tracked_file(args, function, runtime) when function in [:rename, :rename!] do
    [source, target | _rest] = args
    prepared_source = prepare_remove!(source)
    target_before = snapshot_before!(target, runtime)
    result = apply(File, function, args)

    if successful_file_result?(result) do
      journal_or_raise(FilesystemJournal.commit_prepared(prepared_source))
      after_bytes = read_after_bytes!(target)
      journal_or_raise(FilesystemJournal.record_file_write(target, target_before, after_bytes, tool: "eeva"))
    end

    result
  end

  defp call_tracked_file(args, function, runtime) when function in [:cp, :cp!, :cp_r, :cp_r!] do
    [_source, target | _rest] = args
    target_before = snapshot_before!(target, runtime)
    result = apply(File, function, args)

    if successful_file_result?(result) do
      after_bytes = read_after_bytes!(target)
      journal_or_raise(FilesystemJournal.record_file_write(target, target_before, after_bytes, tool: "eeva"))
    end

    result
  end

  defp call_tracked_file(args, function, runtime) when function in [:touch, :touch!, :chmod, :chmod!] do
    [path | _rest] = args
    before_state = snapshot_before!(path, runtime)
    result = apply(File, function, args)

    if successful_file_result?(result) do
      after_bytes = read_after_bytes!(path)
      journal_or_raise(FilesystemJournal.record_file_write(path, before_state, after_bytes, tool: "eeva"))
    end

    result
  end

  defp call_tracked_file(args, function, runtime) when function in [:ln_s, :ln_s!] do
    [_source, target | _rest] = args
    target_before = snapshot_before!(target, runtime)
    result = apply(File, function, args)

    if successful_file_result?(result) do
      journal_or_raise(FilesystemJournal.record_file_write(target, target_before, "", tool: "eeva"))
    end

    result
  end

  defp call_tracked_file(args, function, _runtime), do: apply(File, function, args)

  defp snapshot_before!(path, runtime) do
    case FilesystemJournal.snapshot_state(path, runtime.workspace_root) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp prepare_remove!(path) do
    case FilesystemJournal.record_remove(path, tool: "eeva") do
      {:ok, prepared} -> prepared
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp prepare_remove(path), do: FilesystemJournal.record_remove(path, tool: "eeva")

  defp journal_or_raise(:ok), do: :ok
  defp journal_or_raise({:error, reason}), do: raise(ArgumentError, reason)

  defp successful_file_result?(:ok), do: true
  defp successful_file_result?({:ok, _}), do: true
  defp successful_file_result?({:ok, _paths, []}), do: true
  defp successful_file_result?(paths) when is_list(paths), do: true
  defp successful_file_result?(_), do: false

  defp state_exists?(%{"type" => "absent"}), do: false
  defp state_exists?(_state), do: true

  defp missing_directory_chain(path, runtime) do
    workspace_root = runtime.workspace_root

    path
    |> Path.expand()
    |> Path.relative_to(workspace_root)
    |> Path.split()
    |> Enum.reduce({workspace_root, []}, fn part, {parent, missing} ->
      current = Path.join(parent, part)

      if File.exists?(current) do
        {current, missing}
      else
        {current, missing ++ [current]}
      end
    end)
    |> elem(1)
  end

  defp read_after_bytes!(path) do
    cond do
      File.regular?(path) -> File.read!(path)
      true -> ""
    end
  end

  defp authorize_path(path, mode, runtime) do
    path = to_string(path)
    allow_missing = mode == :write

    with {:ok, absolute} <- PathSafety.resolve(path, allow_missing: allow_missing),
         :ok <- ensure_inside_workspace(absolute, runtime.workspace_root),
         relative <- Path.relative_to(absolute, runtime.workspace_root),
         :ok <- reject_workspace_root_write(relative, mode),
         :ok <- authorize_runtime_path(relative, mode, runtime.policy),
         :ok <- authorize_project_path(relative, mode, runtime.policy) do
      {:ok, absolute}
    end
  end

  defp reject_workspace_root_write(".", :write),
    do: {:error, "Workspace root cannot be mutated directly by Eeva."}

  defp reject_workspace_root_write(_relative, _mode), do: :ok

  defp authorize_runtime_path(_relative, :read, %{mode: :chat}),
    do: {:error, "Filesystem access is unavailable in chat mode."}

  defp authorize_runtime_path(_relative, :read, _policy), do: :ok

  defp authorize_runtime_path(relative, :write, policy) do
    cond do
      policy.mode in [:read_only, :local_context_helper, :invalid_policy, :chat] ->
        {:error, "Workspace mutation is blocked by the active #{policy.mode} policy."}

      policy.mode == :research and not markdown_path?(relative) ->
        {:error, "Research mode may only write Markdown files."}

      policy.mode == :restricted_write and
          not matches_any?(relative, Map.get(policy, :allowed_write_paths, [])) ->
        {:error, "Path #{relative} is outside the active allowed_write_paths."}

      true ->
        :ok
    end
  end

  defp authorize_project_path(relative, mode, policy) do
    if ToolPolicy.project_policy_bypassed?(policy) do
      :ok
    else
      case mode do
        :read -> ProjectPolicy.allowed_read_path?(relative)
        :write -> ProjectPolicy.allowed_write_path?(relative)
      end
    end
  end

  defp authorize_memory_write(runtime) do
    cond do
      runtime.policy.mode in [:local_context_helper, :invalid_policy] ->
        {:error, "Memory mutation is blocked by the active #{runtime.policy.mode} policy."}

      Map.get(runtime.policy, :allow_memory_write, true) ->
        :ok

      true ->
        {:error, "Memory mutation is blocked by the active policy."}
    end
  end

  defp authorize_command(command, args, runtime) do
    cond do
      command in @shell_commands ->
        {:error, "Shell interpreters are unavailable inside Eeva; invoke the executable directly."}

      contains_internal_path?([command | Enum.map(args, &to_string/1)]) ->
        {:error, "Commands cannot access BeamCore internal snapshot, recovery, or memory storage."}

      network_command?(command, args) and not Map.get(runtime.policy, :allow_network, false) ->
        {:error, "Network command #{command} is blocked by the active policy."}

      runtime.policy.mode in [:local_context_helper, :invalid_policy, :chat] ->
        {:error, "Command execution is blocked by the active #{runtime.policy.mode} policy."}

      runtime.policy.mode == :read_only and not read_only_command?(command, args) ->
        {:error, "Command #{command} is not permitted by the read-only policy."}

      not safe_command?(command, args) ->
        {:error,
         "Command #{command} is not permitted inside Eeva unless it is a read-only or validation command. Use File.* APIs for workspace mutations so changes are journaled precisely."}

      unsafe_path_argument?(args, runtime.workspace_root) ->
        {:error, "Command arguments may not address paths outside the workspace."}

      true ->
        :ok
    end
  end

  defp command_options(opts, runtime) do
    requested_cd = Keyword.get(opts, :cd, runtime.workspace_root)

    with {:ok, safe_cd} <- authorize_path(requested_cd, :read, runtime) do
      {:ok,
       opts
       |> Keyword.put(:cd, safe_cd)
       |> Keyword.put_new(:stderr_to_stdout, true)}
    end
  end

  defp read_only_command?("git", [operation | _]),
    do: operation in ["--version", "status", "diff", "log", "show", "grep", "rev-parse", "branch"]

  defp read_only_command?("mix", [operation | _]), do: operation in ["help", "--version"]
  defp read_only_command?(command, args), do: command in @read_only_commands and "--version" in args

  defp safe_command?("git", args), do: read_only_command?("git", args)
  defp safe_command?("mix", ["test" | _]), do: true
  defp safe_command?("mix", ["format", "--check-formatted" | _]), do: true
  defp safe_command?("mix", args), do: read_only_command?("mix", args)
  defp safe_command?("make", [target | _]), do: target in ["test", "check", "validate"]
  defp safe_command?("cargo", [operation | _]), do: operation in ["test", "check", "clippy"]
  defp safe_command?("go", [operation | _]), do: operation in ["test", "vet"]
  defp safe_command?(command, args), do: command in @read_only_commands and "--version" in args

  defp network_command?(command, args) do
    command in @network_commands or
      (command == "git" and Enum.any?(args, &(&1 in ["clone", "fetch", "pull", "push", "ls-remote"])))
  end

  defp unsafe_path_argument?(args, workspace_root) do
    Enum.any?(args, fn arg ->
      value = to_string(arg)

      cond do
        value == "" or String.starts_with?(value, "-") -> false
        URI.parse(value).scheme in ["http", "https", "ssh", "git"] -> false
        Path.type(value) == :absolute -> not String.starts_with?(Path.expand(value), workspace_root <> "/")
        String.contains?(value, "../") -> true
        true -> false
      end
    end)
  end

  defp ensure_inside_workspace(absolute, workspace_root) do
    expanded = Path.expand(absolute)

    if expanded == workspace_root or String.starts_with?(expanded, workspace_root <> "/") do
      :ok
    else
      {:error, "Path escapes the active workspace."}
    end
  end

  defp resolve_pattern(pattern, runtime) do
    prefix =
      pattern
      |> String.split(~r/[\*\?\[]/, parts: 2)
      |> hd()
      |> case do
        "" -> "."
        value -> Path.dirname(value)
      end

    with {:ok, _absolute_prefix} <- authorize_path(prefix, :read, runtime) do
      {:ok, Path.join(runtime.workspace_root, pattern)}
    end
  end

  defp runtime! do
    case Process.get(@process_key) do
      %{policy: policy, workspace_root: workspace_root} ->
        %{policy: policy, workspace_root: workspace_root}

      _ ->
        raise "Eeva policy runtime was not installed in the execution process."
    end
  end

  defp module_from_ast({:__aliases__, _meta, parts}) when is_list(parts), do: Module.concat(parts)
  defp module_from_ast(module) when is_atom(module), do: module
  defp module_from_ast(_), do: nil

  defp network_module?(module),
    do: module in [:gen_tcp, :gen_udp, :ssl, :httpc, Finch, Req, Mint.HTTP]

  defp direct_internal_policy_call?(module), do: module == __MODULE__

  defp write_modes?(modes) when is_list(modes),
    do: Enum.any?(modes, &(&1 in [:write, :append, :exclusive]))

  defp write_modes?(_), do: false

  defp markdown_path?(relative) do
    String.ends_with?(relative, ".md") or relative == "research_index.md"
  end

  defp contains_internal_path?(values) do
    Enum.any?(values, fn value ->
      down = value |> to_string() |> String.downcase()
      String.contains?(down, ".beamcore/snapshots") or
        String.contains?(down, ".beamcore/recovery") or
        String.contains?(down, ".beamcore/memory")
    end)
  end

  defp matches_any?(_relative, []), do: false
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
          {:error, _reason} -> false
        end

      true ->
        false
    end
  end

  defp line(meta) when is_list(meta), do: Keyword.get(meta, :line, 1)
  defp line(_meta), do: 1
end
