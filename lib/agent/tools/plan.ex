defmodule Beamcore.Agent.Tools.Plan do
  @moduledoc """
  Records a compact, non-mutating planning note.
  """

  alias Beamcore.Agent.Tools.PathSafety

  @known_tools ~w(read grep glob edit patch write web_get tree git fs task mix plan image_generation memory python node make go rust terraform ruby bazel)
  @description """
  Propose a compact, non-mutating plan for a user request. This is informational
  only; it does not gate execution or require confirmation.
  """

  def name, do: "plan"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            summary: %{type: "string", description: "Short summary of the planned change"},
            create_files: %{
              type: "array",
              items: %{type: "string"},
              description: "Workspace-relative files to create"
            },
            modify_files: %{
              type: "array",
              items: %{type: "string"},
              description: "Workspace-relative files to modify"
            },
            delete_files: %{
              type: "array",
              items: %{type: "string"},
              description: "Workspace-relative files to delete, if any"
            },
            allowed_tools: %{
              type: "array",
              items: %{type: "string"},
              description: "Tools expected for the work"
            },
            validation: %{type: "string", description: "Validation command or empty string"},
            risks: %{
              type: "array",
              items: %{type: "string"},
              description: "Short assumptions or risks"
            }
          },
          required: ["summary"]
        }
      }
    }
  end

  def execute(params) do
    params
    |> normalize()
    |> encode()
  end

  def normalize(params) when is_map(params) do
    with {:ok, create_files} <- normalize_paths(Map.get(params, "create_files", [])),
         {:ok, modify_files} <- normalize_paths(Map.get(params, "modify_files", [])),
         {:ok, delete_files} <- normalize_paths(Map.get(params, "delete_files", [])) do
      allowed_tools = allowed_tools(params, create_files, modify_files)

      %{
        "ok" => true,
        "summary" => "Plan noted. Continue autonomously; no confirmation is required.",
        "plan" => %{
          "summary" => compact_string(Map.get(params, "summary", "Planned change")),
          "create_files" => create_files,
          "modify_files" => modify_files,
          "delete_files" => delete_files,
          "allowed_tools" => allowed_tools,
          "validation" => compact_string(Map.get(params, "validation", "")),
          "risks" => compact_list(Map.get(params, "risks", []))
        },
        "pending_action" => nil
      }
    else
      {:error, reason} ->
        %{
          "ok" => false,
          "summary" => "Plan rejected: #{reason}",
          "pending_action" => nil
        }
    end
  end

  def normalize(_params) do
    %{"ok" => false, "summary" => "Plan rejected: parameters must be an object."}
  end

  defp normalize_paths(values) do
    values
    |> list()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, paths} ->
      case normalize_path(path) do
        {:ok, normalized} -> {:cont, {:ok, paths ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.uniq(paths)}
      error -> error
    end
  end

  defp normalize_path(path) when is_binary(path) do
    with {:ok, absolute} <- PathSafety.resolve(path, allow_missing: true) do
      {:ok, Path.relative_to(absolute, PathSafety.workspace_root())}
    end
  end

  defp normalize_path(_path), do: {:error, "planned paths must be strings"}

  defp allowed_tools(params, create_files, modify_files) do
    requested = params |> Map.get("allowed_tools", []) |> list()

    inferred =
      []
      |> maybe_add_tool("write", create_files != [])
      |> maybe_add_tool("edit", modify_files != [])
      |> maybe_add_tool("patch", modify_files != [])
      |> maybe_add_tool("mix", compact_string(Map.get(params, "validation", "")) != "")

    (["read"] ++ requested ++ inferred)
    |> Enum.filter(&(&1 in @known_tools))
    |> Enum.reject(&(&1 in ["task", "web_get", "git", "fs", "plan"]))
    |> Enum.uniq()
  end

  defp maybe_add_tool(tools, tool, true), do: tools ++ [tool]
  defp maybe_add_tool(tools, _tool, false), do: tools

  defp list(values) when is_list(values), do: values
  defp list(value) when is_binary(value) and value != "", do: [value]
  defp list(_value), do: []

  defp compact_list(values) do
    values
    |> list()
    |> Enum.map(&compact_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(6)
  end

  defp compact_string(value) when is_binary(value) do
    value = String.trim(value)

    if String.length(value) > 240 do
      String.slice(value, 0, 240) <> "... [truncated]"
    else
      value
    end
  end

  defp compact_string(value), do: value |> to_string() |> compact_string()

  defp encode(result), do: Jason.encode!(result)
end
