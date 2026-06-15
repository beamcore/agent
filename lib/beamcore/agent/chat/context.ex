defmodule Beamcore.Agent.Chat.Context do
  @moduledoc """
  Compact per-session context for the single Eeva execution surface.

  The context stores only metadata and compact summaries. It never stores full
  file contents.
  """

  defstruct inspected_files: MapSet.new(),
            active_constraints: [],
            current_task: nil,
            blocked_attempts: []

  @max_summary_chars 1_500
  @max_items 12
  @default_constraints [
    "All executable work goes through Eeva.",
    "Eeva executions are OTP-supervised.",
    "Normal allowed work is autonomous; hard runtime boundaries are automatic."
  ]

  def new do
    %__MODULE__{active_constraints: @default_constraints}
  end

  def compact(%__MODULE__{} = context) do
    %{
      context
      | inspected_files:
          context.inspected_files |> MapSet.to_list() |> Enum.take(20) |> MapSet.new(),
        blocked_attempts: Enum.take(context.blocked_attempts, 3),
        current_task: context.current_task
    }
  end

  def from_user_request(%__MODULE__{} = context, content, _caps) do
    Map.put(context, :current_task, compact_text(content, 240))
  end

  def update_from_tool(%__MODULE__{} = context, "eeva", args, result) do
    context
    |> maybe_record_blocked_attempt("eeva", args, result)
    |> record_eeva_inspected_files(args)
  end

  def update_from_tool(%__MODULE__{} = context, _name, _args, _result), do: context

  def to_message(%__MODULE__{} = context), do: %{role: "system", content: summary(context)}

  def summary(%__MODULE__{} = context) do
    [
      "Known session context:",
      list_line("Inspected this session", context.inspected_files),
      list_line("Active constraints", context.active_constraints),
      list_line("Blocked attempts", context.blocked_attempts),
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

  defp normalize_path(path) when is_binary(path) do
    path
    |> Path.expand("/")
    |> Path.relative_to("/")
  end

  defp prepend_unique(list, item),
    do: [item | Enum.reject(list, &(&1 == item))] |> Enum.take(@max_items)

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

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

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
