defmodule Beamcore.Agent.Core.ToolDisplay do
  @moduledoc """
  Pure display helpers for compact tool presentation.

  This module intentionally has no IO, ANSI styling, ExRatatui structs, policy
  checks, or runtime side effects. Renderers can use the returned strings/data in
  their own presentation layer.
  """

  @default_limit 180

  def activity(name, args, status, result \\ nil) do
    name = to_string(name)
    target = target(name, args)

    %{
      name: name,
      target: target,
      status: status,
      label: label(name, args, target, status),
      summary: summary(name, args, result),
      result: result_summary(result)
    }
  end

  def label(name, args, status \\ :done) do
    name = to_string(name)
    label(name, args, target(name, args), status)
  end

  def target("image_generation", args), do: Map.get(args, "output_path")
  def target("policy", args), do: Map.get(args, "target") || Map.get(args, "action")
  def target("mix", args), do: compact_join([Map.get(args, "command"), Map.get(args, "args")])
  def target("git", args), do: Map.get(args, "operation") || Map.get(args, "command")
  def target("fs", args), do: Map.get(args, "path") || Map.get(args, "target")
  def target("task", args), do: Map.get(args, "name")

  def target(name, args) when name in ~w(python node make go rust terraform ruby bazel),
    do: compact_join([Map.get(args, "command"), Map.get(args, "target")])

  def target(_name, args),
    do: Map.get(args, "filePath") || Map.get(args, "path") || Map.get(args, "pattern")

  def label(name, args, target, :blocked), do: blocked_label(name, args, target)

  def label("image_generation", _args, target, _status),
    do: compact_join(["image_generation ->", target]) || "image_generation"

  def label("policy", args, target, _status),
    do: compact_join(["policy", Map.get(args, "action"), target])

  def label("modify_file", args, target, _status) do
    cond do
      Map.has_key?(args, "content") ->
        compact_join(["modify_file (write)", target, byte_badge(args)])

      Map.has_key?(args, "edits") ->
        compact_join(["modify_file (edit)", target, modify_badge(args)])

      true ->
        compact_join(["modify_file", target])
    end
  end

  def label("fs", args, target, _status),
    do: compact_join(["fs", Map.get(args, "operation"), target])

  def label("git", args, _target, _status),
    do:
      compact_join([
        "git",
        Map.get(args, "operation") || Map.get(args, "command"),
        Map.get(args, "path")
      ])

  def label("mix", args, _target, _status),
    do: compact_join(["mix", Map.get(args, "command"), Map.get(args, "args")])

  def label(name, args, _target, _status)
      when name in ~w(python node make go rust terraform ruby bazel),
      do:
        compact_join([
          name,
          Map.get(args, "command"),
          Map.get(args, "target"),
          Map.get(args, "args")
        ])

  def label("task", args, target, _status),
    do: compact_join(["task", target || "sub-agent", model_badge(args)])

  def label("grep", args, target, _status),
    do: compact_join(["grep", quote_compact(Map.get(args, "pattern")), "in", target])

  def label("glob", args, target, _status),
    do: compact_join(["glob", quote_compact(Map.get(args, "pattern")), "in", target])

  def label(name, _args, nil, _status), do: name
  def label(name, _args, "", _status), do: name
  def label(name, _args, target, _status), do: "#{name} #{target}"

  def blocked_label(name, args, target \\ nil) do
    target = target || target(to_string(name), args)
    normal = label(to_string(name), args, target, :done)
    compact_join(["blocked", normal]) || "blocked #{name}"
  end

  def summary("image_generation", args, result) do
    prompt = compact_text(Map.get(args, "prompt", ""), 90)
    output = Map.get(args, "output_path")
    saved = saved_path(result)

    [prompt, output && "output #{output}", saved && "saved #{saved}", saved && "open #{saved}"]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  def summary("plan", args, _result) do
    files =
      ["create_files", "modify_files", "delete_files"]
      |> Enum.flat_map(&(Map.get(args, &1, []) || []))
      |> Enum.take(5)
      |> Enum.join(", ")

    compact_text((files == "" && Map.get(args, "summary", "plan")) || files)
  end

  def summary("policy", args, result) do
    [Map.get(args, "message"), result_summary(result)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> compact_text()
  end

  def summary("modify_file", args, _result) do
    cond do
      Map.has_key?(args, "content") ->
        byte_summary(args)

      Map.has_key?(args, "edits") ->
        modify_summary(args)

      true ->
        ""
    end
  end

  def summary("fs", args, _result),
    do: key_values([{"op", Map.get(args, "operation")}, {"target", Map.get(args, "target")}])

  def summary("git", args, _result),
    do:
      key_values([
        {"op", Map.get(args, "operation") || Map.get(args, "command")},
        {"path", Map.get(args, "path")},
        {"base", Map.get(args, "base")},
        {"workdir", Map.get(args, "workdir")}
      ])

  def summary("mix", args, _result),
    do: key_values([{"command", Map.get(args, "command")}, {"args", Map.get(args, "args")}])

  def summary(name, args, _result)
      when name in ~w(python node make go rust terraform ruby bazel),
      do:
        key_values([
          {"command", Map.get(args, "command")},
          {"target", Map.get(args, "target")},
          {"args", Map.get(args, "args")},
          {"workdir", Map.get(args, "workdir")}
        ])

  def summary("task", args, _result),
    do:
      key_values([
        {"name", Map.get(args, "name")},
        {"model", Map.get(args, "model", "default")},
        {"prompt", compact_text(Map.get(args, "prompt", ""), 72)}
      ])

  def summary("read", args, result),
    do:
      key_values([
        {"path", Map.get(args, "filePath") || Map.get(args, "path")},
        {"range", range_summary(args)},
        {"result", result_summary(result)}
      ])

  def summary("grep", args, result),
    do:
      key_values([
        {"pattern", Map.get(args, "pattern")},
        {"path", Map.get(args, "path", ".")},
        {"result", result_summary(result)}
      ])

  def summary("glob", args, result),
    do:
      key_values([
        {"pattern", Map.get(args, "pattern")},
        {"path", Map.get(args, "path", ".")},
        {"result", result_summary(result)}
      ])

  def summary(_name, _args, result), do: result_summary(result)

  def result_status("Error: Tool call blocked" <> _), do: :blocked
  def result_status("Error: Mutation requires" <> _), do: :blocked
  def result_status("Error: " <> _), do: :error
  def result_status(_result), do: :done

  def result_summary(nil), do: ""
  def result_summary("Error: " <> reason), do: compact_text(reason)

  def result_summary(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"summary" => summary}} ->
        compact_text(summary)

      {:ok, %{"ok" => true, "files" => files}} when is_list(files) ->
        compact_text(Enum.join(files, ", "))

      _ ->
        compact_text(result)
    end
  end

  def result_summary(result), do: compact_text(inspect(result, limit: 4, printable_limit: 160))

  def byte_summary(args) do
    content = Map.get(args, "content") || ""
    if content == "", do: "", else: "#{byte_size(content)} bytes"
  end

  def modify_summary(args) do
    edits = Map.get(args, "edits") || []
    count = length(edits)
    "#{count} edits"
  end

  def modify_badge(args) do
    edits = Map.get(args, "edits") || []
    count = length(edits)
    "(#{count} edits)"
  end

  def byte_badge(args) do
    content = Map.get(args, "content", "")
    if content == "", do: nil, else: "(#{byte_size(content)} bytes)"
  end

  def model_badge(args) do
    case Map.get(args, "model") do
      nil -> nil
      "" -> nil
      model -> "(#{model})"
    end
  end

  def range_summary(args) do
    case {Map.get(args, "offset"), Map.get(args, "limit")} do
      {nil, nil} -> nil
      {offset, nil} -> "from #{offset}"
      {nil, limit} -> "limit #{limit}"
      {offset, limit} -> "#{offset}+#{limit}"
    end
  end

  def key_values(pairs, suffix \\ "") do
    pairs
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.map(fn {key, value} -> "#{key}: #{value}#{suffix}" end)
    |> Enum.join(" · ")
    |> case do
      "" -> ""
      text -> compact_text(text)
    end
  end

  def compact_text(value, limit \\ @default_limit) do
    value
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(limit)
  end

  def compact_join(values) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp quote_compact(nil), do: nil
  defp quote_compact(""), do: nil
  defp quote_compact(value), do: ~s("#{compact_text(value, 36)}")

  defp saved_path(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"files" => [file | _]}} -> file
      {:ok, %{"saved" => file}} -> file
      _ -> nil
    end
  end

  defp saved_path(_result), do: nil

  defp truncate(text, limit) when byte_size(text) <= limit, do: text
  defp truncate(text, limit), do: String.slice(text, 0, max(limit - 3, 0)) <> "..."
end
