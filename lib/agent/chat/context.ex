defmodule Beamcore.Agent.Chat.Context do
  @moduledoc """
  Compact per-session context for the single Eeva execution surface.

  The context stores only metadata and compact summaries. It never stores full
  file contents or a duplicate copy of the reversible filesystem journal.
  """

  defstruct project_type: :unknown,
            inspected_files: MapSet.new(),
            modified_files: MapSet.new(),
            last_validation: nil,
            decisions: [],
            active_constraints: [],
            current_task: nil,
            blocked_attempts: [],
            pending_action: nil,
            known_risks: []

  @max_summary_chars 1_500
  @max_items 12
  @default_constraints [
    "All executable work goes through Eeva.",
    "Eeva executions are OTP-supervised and workspace changes are journaled.",
    "Normal allowed work is autonomous; policy rejection is automatic."
  ]

  def new(language \\ :unknown, build_system \\ :unknown) do
    %__MODULE__{project_type: {language, build_system}, active_constraints: @default_constraints}
  end

  def compact(%__MODULE__{} = context) do
    %{
      context
      | inspected_files:
          context.inspected_files |> MapSet.to_list() |> Enum.take(20) |> MapSet.new(),
        modified_files: context.modified_files,
        decisions: Enum.take(context.decisions, 6),
        blocked_attempts: Enum.take(context.blocked_attempts, 3),
        known_risks: Enum.take(context.known_risks, 3)
    }
  end

  def from_user_request(%__MODULE__{} = context, content, policy) do
    context
    |> Map.put(:current_task, compact_text(content, 240))
    |> put_constraints(policy)
  end

  def clear_policy_blocks(%__MODULE__{} = context) do
    %{
      context
      | blocked_attempts: [],
        active_constraints: Enum.reject(context.active_constraints, &policy_block_text?/1),
        known_risks: Enum.reject(context.known_risks, &policy_block_text?/1)
    }
  end

  def update_from_tool(%__MODULE__{} = context, "eeva", args, result) do
    context
    |> maybe_record_blocked_attempt("eeva", args, result)
    |> record_eeva_inspected_files(args)
    |> update_eeva(result)
  end

  def update_from_tool(%__MODULE__{} = context, _name, _args, _result), do: context

  def to_message(%__MODULE__{} = context), do: %{role: "system", content: summary(context)}

  def summary(%__MODULE__{} = context) do
    [
      "Known session context:",
      "- Project type: #{format_project_type(context.project_type)}",
      list_line("Inspected this session", context.inspected_files),
      list_line("Modified this session", context.modified_files),
      list_line("Active constraints", context.active_constraints),
      list_line("Decisions", context.decisions),
      list_line("Blocked attempts", context.blocked_attempts),
      list_line("Known risks", context.known_risks),
      task_line(context.current_task)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> compact_text(@max_summary_chars)
  end

  defp record_eeva_inspected_files(context, args) do
    code = Map.get(args, "code") || Map.get(args, :code) || ""

    paths =
      Regex.scan(
        ~r/File\.(?:read|read!|stream!|stat|stat!|lstat|lstat!|exists\?|dir\?|regular\?)\(\s*["']([^"']+)["']/,
        code,
        capture: :all_but_first
      )
      |> List.flatten()

    Enum.reduce(paths, context, fn path, current ->
      %{current | inspected_files: MapSet.put(current.inspected_files, normalize_path(path))}
    end)
  end

  defp update_eeva(context, result) do
    result
    |> decode_json()
    |> Map.get("filesystem_changes", %{})
    |> Map.get("mutations", [])
    |> Enum.reduce(context, fn mutation, current ->
      current
      |> add_modified(Map.get(mutation, "path"))
      |> add_modified(Map.get(mutation, "target_path"))
    end)
  end

  defp maybe_record_blocked_attempt(context, name, args, result) when is_binary(result) do
    parsed = decode_json(result)
    summary = Map.get(parsed, "summary", result)

    if Map.get(parsed, "ok") == false and blocked_summary?(summary) do
      attempt =
        [name, Map.get(args, "code") |> compact_text(80)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")
        |> compact_text(120)

      %{context | blocked_attempts: prepend_unique(context.blocked_attempts, attempt)}
    else
      context
    end
  end

  defp maybe_record_blocked_attempt(context, _name, _args, _result), do: context

  defp blocked_summary?(summary) when is_binary(summary) do
    text = String.downcase(summary)
    String.contains?(text, "blocked") or String.contains?(text, "not available")
  end

  defp blocked_summary?(_summary), do: false

  defp put_constraints(context, policy) do
    constraints =
      context.active_constraints
      |> maybe_add_constraint(policy[:mode] == :read_only, "Current session policy is read-only.")
      |> maybe_add_constraint(
        policy[:mode] == :restricted_write,
        "Restricted-write policy is active."
      )

    %{context | active_constraints: constraints}
  end

  defp maybe_add_constraint(constraints, true, constraint),
    do: prepend_unique(constraints, constraint)

  defp maybe_add_constraint(constraints, false, _constraint), do: constraints

  defp add_modified(context, nil), do: context

  defp add_modified(context, path),
    do: %{context | modified_files: MapSet.put(context.modified_files, normalize_path(path))}

  defp normalize_path(path) when is_binary(path) do
    path
    |> Path.expand("/")
    |> Path.relative_to("/")
  end

  defp normalize_path(path), do: to_string(path)

  defp prepend_unique(list, item),
    do: [item | Enum.reject(list, &(&1 == item))] |> Enum.take(@max_items)

  defp format_project_type({language, build_system}), do: "#{language} (#{build_system})"
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

  defp task_line(nil), do: nil
  defp task_line(task), do: "- Current task: #{task}"

  defp policy_block_text?(value) when is_binary(value) do
    text = String.downcase(value)
    String.contains?(text, "project policy") or String.contains?(text, "blocked by policy")
  end

  defp policy_block_text?(_), do: false

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_json(_), do: %{}

  defp compact_text(nil, _max_chars), do: ""

  defp compact_text(text, max_chars) when is_binary(text) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "... [truncated]"
    else
      text
    end
  end

  defp compact_text(text, max_chars), do: text |> to_string() |> compact_text(max_chars)
end
