defmodule Beamcore.Agent.Chat.Context do
  @moduledoc """
  Compact per-session project context.

  This module stores metadata only: paths, short decisions, compact validation
  summaries, and blocked attempts. It intentionally never stores file contents.
  """

  defstruct project_type: :unknown,
            inspected_files: MapSet.new(),
            modified_files: MapSet.new(),
            last_validation: nil,
            decisions: [],
            active_constraints: [],
            current_task: nil,
            pending_action: nil,
            blocked_attempts: [],
            known_risks: []

  @max_summary_chars 1_500
  @max_items 12
  @default_constraints [
    "No shell tool.",
    "Workspace-relative paths only.",
    "No real API calls from tools or tests."
  ]

  def new(language \\ :unknown, build_system \\ :unknown) do
    %__MODULE__{project_type: {language, build_system}, active_constraints: @default_constraints}
  end

  @doc """
  Returns a compacted version of the context for session rollover.
  Preserves modified_files and project_type fully.
  Trims lower-priority tracking lists.
  """
  def compact(%__MODULE__{} = context) do
    %{
      context
      | inspected_files:
          context.inspected_files |> MapSet.to_list() |> Enum.take(20) |> MapSet.new(),
        modified_files: context.modified_files,
        decisions: Enum.take(context.decisions, 6),
        blocked_attempts: Enum.take(context.blocked_attempts, 3),
        known_risks: Enum.take(context.known_risks, 3),
        last_validation: context.last_validation,
        pending_action: nil
    }
  end

  def from_user_request(%__MODULE__{} = context, content, policy) do
    context
    |> Map.put(:current_task, compact_text(content, 240))
    |> Map.put(:pending_action, nil)
    |> put_constraints(policy)
  end

  def put_pending_action(%__MODULE__{} = context, pending_action) do
    %{context | pending_action: pending_action}
  end

  def clear_pending_action(%__MODULE__{} = context) do
    %{context | pending_action: nil}
  end

  def clear_policy_blocks(%__MODULE__{} = context) do
    %{
      context
      | blocked_attempts: [],
        active_constraints:
          Enum.reject(context.active_constraints, fn constraint ->
            String.starts_with?(constraint, "Current turn") or
              String.starts_with?(constraint, "Restricted writes only") or
              policy_block_text?(constraint)
          end),
        known_risks: Enum.reject(context.known_risks, &policy_block_text?/1)
    }
  end

  defp policy_block_text?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> then(fn text ->
      String.contains?(text, "project policy") or String.contains?(text, "blocked by policy")
    end)
  end

  defp policy_block_text?(_value), do: false

  def update_from_tool(%__MODULE__{} = context, name, args, result) do
    context
    |> maybe_record_blocked_attempt(name, args, result)
    |> do_update_from_tool(name, args, result)
  end

  def to_message(%__MODULE__{} = context) do
    %{role: "system", content: summary(context)}
  end

  def summary(%__MODULE__{} = context) do
    lines =
      [
        "Known session context:",
        "- Project type: #{format_project_type(context.project_type)}",
        list_line("Already inspected", context.inspected_files),
        list_line("Modified this session", context.modified_files),
        validation_line(context.last_validation),
        list_line("Active constraints", context.active_constraints),
        list_line("Decisions", context.decisions),
        list_line("Blocked attempts", context.blocked_attempts),
        list_line("Known risks", context.known_risks),
        pending_action_line(context.pending_action),
        task_line(context.current_task),
        "- Do not reread files unless the current task needs fresh exact content."
      ]
      |> Enum.reject(&is_nil/1)

    lines
    |> Enum.join("\n")
    |> compact_text(@max_summary_chars)
  end

  defp do_update_from_tool(context, name, args, result) do
    case name do
      "read" ->
        add_inspected(context, path_arg(args) || "unknown")

      "tree" ->
        add_inspected(context, Map.get(args, "path", "."))

      "grep" ->
        add_inspected(context, Map.get(args, "path", "."))

      "glob" ->
        add_inspected(context, Map.get(args, "path", "."))

      "modify_file" ->
        add_modified(context, path_arg(args))

      "fs" ->
        update_fs(context, args)

      "mix" ->
        update_validation(context, args, result)

      "plan" ->
        update_pending_action(context, args, result)

      "image_generation" ->
        add_modified(context, Map.get(args, "output_path"))

      _ ->
        context
    end
  end

  defp update_fs(context, %{"operation" => operation} = args)
       when operation in ["mkdir", "touch", "move", "copy", "remove"] do
    context
    |> add_modified(Map.get(args, "path"))
    |> add_modified(Map.get(args, "target"))
  end

  defp update_fs(context, _args), do: context

  defp update_validation(context, args, result) do
    command = Map.get(args, "command")

    if command in ["format", "compile", "test", "validate"] do
      parsed = decode_json(result)

      validation = %{
        command: command,
        ok: Map.get(parsed, "ok"),
        summary: parsed |> Map.get("summary", to_string(result)) |> compact_text(180)
      }

      %{context | last_validation: validation}
    else
      context
    end
  end

  defp update_pending_action(context, _args, result) do
    parsed = decode_json(result)

    if Map.get(parsed, "ok") do
      pending_action =
        parsed
        |> Map.get("pending_action", %{})
        |> atomize_pending_action()

      put_pending_action(context, pending_action)
    else
      context
    end
  end

  defp maybe_record_blocked_attempt(context, name, args, result) when is_binary(result) do
    if String.starts_with?(result, "Error: Tool call blocked") do
      attempt =
        [name, path_arg(args) || Map.get(args, "operation")]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> compact_text(120)

      %{context | blocked_attempts: prepend_unique(context.blocked_attempts, attempt)}
    else
      context
    end
  end

  defp maybe_record_blocked_attempt(context, _name, _args, _result), do: context

  defp put_constraints(context, policy) do
    constraints =
      context.active_constraints
      |> maybe_add_constraint(policy[:mode] == :read_only, "Current turn is read-only.")
      |> maybe_add_constraint(
        policy[:mode] == :restricted_write,
        "Restricted writes only: #{Enum.join(policy[:allowed_write_paths] || [], ", ")}."
      )

    %{context | active_constraints: constraints}
  end

  defp maybe_add_constraint(constraints, true, constraint),
    do: prepend_unique(constraints, constraint)

  defp maybe_add_constraint(constraints, false, _constraint), do: constraints

  defp add_inspected(context, nil), do: context

  defp add_inspected(context, path),
    do: %{context | inspected_files: MapSet.put(context.inspected_files, normalize_path(path))}

  defp add_modified(context, nil), do: context

  defp add_modified(context, path),
    do: %{context | modified_files: MapSet.put(context.modified_files, normalize_path(path))}

  defp normalize_path(path) when is_binary(path) do
    path
    |> Path.expand("/")
    |> Path.relative_to("/")
  end

  defp normalize_path(path), do: to_string(path)

  defp path_arg(args), do: Map.get(args, "filePath") || Map.get(args, "path")

  defp prepend_unique(list, item) do
    [item | Enum.reject(list, &(&1 == item))]
    |> Enum.take(@max_items)
  end

  defp format_project_type({language, build_system}) do
    "#{language} (#{build_system})"
  end

  defp format_project_type(type), do: to_string(type)

  defp list_line(_label, nil), do: nil

  defp list_line(label, set) when is_struct(set, MapSet),
    do: list_line(label, MapSet.to_list(set))

  defp list_line(_label, []), do: nil

  defp list_line(label, items) do
    visible = items |> Enum.take(@max_items) |> Enum.join(", ")
    suffix = if length(items) > @max_items, do: ", ...", else: ""
    "- #{label}: #{visible}#{suffix}"
  end

  defp validation_line(nil), do: nil

  defp validation_line(%{command: command, ok: ok, summary: summary}) do
    "- Last validation: mix #{command} #{if ok, do: "passed", else: "failed"}; #{summary}"
  end

  defp pending_action_line(nil), do: nil

  defp pending_action_line(%{summary: summary, allowed_write_paths: paths}) do
    "- Pending action: #{summary}; allowed writes: #{Enum.join(paths, ", ")}."
  end

  defp task_line(nil), do: nil
  defp task_line(task), do: "- Current task: #{task}"

  defp atomize_pending_action(action) when is_map(action) do
    policy = Map.get(action, "policy", %{})
    allowed_write_paths = Map.get(policy, "allowed_write_paths", [])
    allowed_tools = Map.get(policy, "allowed_tools", [])

    %{
      summary: Map.get(action, "summary", "Planned change"),
      create_files: Map.get(action, "create_files", []),
      modify_files: Map.get(action, "modify_files", []),
      delete_files: Map.get(action, "delete_files", []),
      allowed_tools: allowed_tools,
      validation: Map.get(action, "validation", ""),
      risks: Map.get(action, "risks", []),
      allowed_write_paths: allowed_write_paths,
      policy:
        Beamcore.Agent.Chat.ToolPolicy.restricted_write_policy(allowed_write_paths, allowed_tools)
    }
  end

  defp atomize_pending_action(_action), do: nil



  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json(_value), do: %{}

  defp compact_text(text, max_chars) when is_binary(text) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "... [truncated]"
    else
      text
    end
  end

  defp compact_text(text, max_chars), do: text |> to_string() |> compact_text(max_chars)
end
