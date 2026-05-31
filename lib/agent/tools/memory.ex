defmodule Beamcore.Agent.Tools.Memory do
  @moduledoc """
  Agent tool to interact with the persistent Memory service.
  Allows agents to remember, recall, forget, and list knowledge.
  """

  alias Beamcore.Memory

  @description """
  Recall, remember, forget, or list knowledge in the agent's persistent memory.
  Scapes memory by org, repo, and category type. Useful for preserving architecture notes,
  coding conventions, recurring errors/fixes, and decisions across runs.
  """

  def name, do: "memory"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            action: %{
              type: "string",
              description: "The memory action to perform",
              enum: ["remember", "recall", "forget", "list"]
            },
            key: %{
              type: "string",
              description:
                "The memory key to identify this entry (required for remember, recall, forget). MUST be a descriptive snake_case string (e.g. 'user_preferences', 'loop_fix_2026'). Do NOT squash into a single compressed word (e.g. NOT 'userpreferencecats')."
            },
            value: %{
              type: "string",
              description: "The content/value of the memory (required only for remember)"
            },
            type: %{
              type: "string",
              description: "The category type of this memory",
              enum: ["repo_map", "patterns", "decisions", "errors", "context"]
            }
          },
          required: ["action"]
        }
      }
    }
  end

  def execute(params) do
    action = Map.get(params, "action")
    key = Map.get(params, "key")
    value = Map.get(params, "value")
    type_str = Map.get(params, "type") || "context"

    # Check if we're in a git repository
    case Beamcore.Agent.Workspace.current_context() do
      nil ->
        "Error: Memory is only available when running inside a git repository."

      {org, repo} ->
        with {:ok, action_atom} <- validate_action(action),
             {:ok, type_atom} <- validate_type(type_str) do
          case action_atom do
            :remember ->
              if is_nil(key) || String.trim(key) == "" do
                "Error: key is required for remember action."
              else
                if is_nil(value) || String.trim(value) == "" do
                  "Error: value is required for remember action."
                else
                  case Memory.remember(org, repo, type_atom, key, value) do
                    :ok -> "Successfully remembered #{type_str} memory under key '#{key}'."
                    {:error, reason} -> "Error saving memory: #{inspect(reason)}"
                  end
                end
              end

            :recall ->
              if is_nil(key) || String.trim(key) == "" do
                "Error: key is required for recall action."
              else
                case Memory.recall(org, repo, type_atom, key) do
                  nil -> "No #{type_str} memory found for key '#{key}'."
                  val -> "Recalled #{type_str} memory for '#{key}':\n#{val}"
                end
              end

            :forget ->
              if is_nil(key) || String.trim(key) == "" do
                "Error: key is required for forget action."
              else
                case Memory.forget(org, repo, type_atom, key) do
                  :ok -> "Successfully forgot #{type_str} memory for key '#{key}'."
                  {:error, reason} -> "Error forgetting memory: #{inspect(reason)}"
                end
              end

            :list ->
              case Memory.list(org, repo, type_atom) do
                [] ->
                  "No memories found for type #{type_str}."

                memories ->
                  list_str =
                    memories
                    |> Enum.map(fn {k, v} -> "- #{k}: #{short_summary(v)}" end)
                    |> Enum.join("\n")

                  "Memories for type #{type_str}:\n#{list_str}"
              end
          end
        else
          {:error, reason} -> "Error: #{reason}"
        end
    end
  end

  # --- Helpers ---

  defp validate_action(action) do
    case action do
      "remember" ->
        {:ok, :remember}

      "recall" ->
        {:ok, :recall}

      "forget" ->
        {:ok, :forget}

      "list" ->
        {:ok, :list}

      nil ->
        {:error, "action is required"}

      other ->
        {:error, "Invalid action '#{other}'. Must be one of remember, recall, forget, list"}
    end
  end

  defp validate_type(type) do
    case type do
      "repo_map" ->
        {:ok, :repo_map}

      "patterns" ->
        {:ok, :patterns}

      "decisions" ->
        {:ok, :decisions}

      "errors" ->
        {:ok, :errors}

      "context" ->
        {:ok, :context}

      other ->
        {:error,
         "Invalid type '#{other}'. Must be one of repo_map, patterns, decisions, errors, context"}
    end
  end

  defp short_summary(value) when is_binary(value) do
    value = String.trim(value) |> String.replace("\n", " ")

    if String.length(value) > 60 do
      String.slice(value, 0, 57) <> "..."
    else
      value
    end
  end

  defp short_summary(value), do: inspect(value, limit: 10)
end
