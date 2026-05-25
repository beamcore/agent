defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Policy.ProjectPolicy

  @doc """
  Handle a command and return the updated session.
  """
  def execute(command, session, opts \\ []) do
    output = Keyword.get(opts, :output, &IO.puts/1)
    custom_output? = Keyword.has_key?(opts, :output)

    case command do
      "new" -> handle_new(session, output)
      "confirm" -> handle_confirm(session, output)
      "cancel" -> handle_cancel(session, output)
      "context" -> handle_context(session, output)
      "context clear" -> handle_context_clear(session, output)
      "yolo" -> handle_yolo(session, output)
      "help" -> handle_help(session, output)
      "policy" -> handle_policy([], session, output)
      "policy " <> args -> handle_policy(String.split(args, " ", trim: true), session, output)
      _ -> handle_unknown(command, session, output, custom_output?)
    end
  end

  defp handle_new(session, output) do
    output.("Starting new session...")

    session.client
    |> Session.new()
    |> then(& &1)
  end

  defp handle_yolo(session, output) do
    output.("🚀 YOLO mode enabled! All tools are now active and unrestricted.")
    %{session | policy_override: Beamcore.Agent.Chat.ToolPolicy.yolo()}
  end

  defp handle_help(session, output) do
    output.("""
    Available commands:
      /new  - Start a new chat session
      /context - Show compact session context
      /context clear - Clear compact session context
      /policy - Show project policy summary
      /policy show - Show normalized project policy config
      /policy init - Create .beamcore/policy.json from the example
      /policy deny path <pattern> - Add a denied path pattern
      /policy allow-write <pattern> - Add an allowed write path pattern
      /policy read-only <pattern> - Add a read-only path pattern
      /policy tool <tool> allow|deny - Set tool permission
      /policy reload - Reload and summarize project policy
      /yolo - Enable all tools with unrestricted access
      /help - Show this help message
    """)

    session
  end

  defp handle_context(session, output) do
    output.(
      [
        Beamcore.Agent.Chat.Context.summary(session.context),
        ProjectPolicy.summary(ProjectPolicy.load())
      ]
      |> Enum.join("\n")
    )

    session
  end

  defp handle_context_clear(session, output) do
    output.("Session context cleared.")
    %{session | context: Beamcore.Agent.Chat.Context.new(session.project_nature)}
  end

  defp handle_policy(args, session, output) do
    message =
      case policy_command(args) do
        {:show_summary} ->
          ProjectPolicy.summary(ProjectPolicy.load())

        {:show_config} ->
          ProjectPolicy.load() |> ProjectPolicy.show()

        {:init} ->
          case ProjectPolicy.init() do
            {:ok, policy} -> "Project policy initialized: #{ProjectPolicy.summary(policy)}"
            {:error, reason} -> "Error: #{reason}"
          end

        {:reload} ->
          "Project policy reloaded. #{ProjectPolicy.summary(ProjectPolicy.load())}"

        {:reset, confirmed?} ->
          if confirmed? do
            reset_policy()
          else
            "Error: /policy reset weakens policy. Re-run with --confirm."
          end

        {:mutate, action, confirmed?} ->
          mutate_policy(action, confirmed?)

        {:error, reason} ->
          "Error: #{reason}"
      end

    output.(message)
    session
  end

  defp handle_confirm(%{context: %{pending_action: nil}} = session, output) do
    output.("No pending action to confirm.")
    session
  end

  defp handle_confirm(%{pending_user_message: nil} = session, output) do
    output.("No pending action to confirm.")
    session
  end

  defp handle_confirm(session, output) do
    pending_action = session.context.pending_action
    confirmed_content = confirmed_execution_content(session.pending_user_message, pending_action)
    confirmed_session = Session.clear_pending_action(session)

    output.("Confirmed pending action.")
    {:run_pending, confirmed_session, confirmed_content, pending_action.policy}
  end

  defp handle_cancel(%{context: %{pending_action: nil}} = session, output) do
    output.("No pending action to cancel.")
    session
  end

  defp handle_cancel(session, output) do
    output.("Pending action canceled.")
    Session.clear_pending_action(session)
  end

  defp policy_command([]), do: {:show_summary}
  defp policy_command(["show"]), do: {:show_config}
  defp policy_command(["reload"]), do: {:reload}
  defp policy_command(["init"]), do: {:init}
  defp policy_command(["reset" | rest]), do: {:reset, confirm_flag?(rest)}

  defp policy_command(["deny", "path", pattern | rest]),
    do: {:mutate, {:add_deny, pattern}, confirm_flag?(rest)}

  defp policy_command(["allow-write", pattern | rest]),
    do: {:mutate, {:add_allow_write, pattern}, confirm_flag?(rest)}

  defp policy_command(["read-only", pattern | rest]),
    do: {:mutate, {:add_read_only, pattern}, confirm_flag?(rest)}

  defp policy_command(["tool", tool, permission | rest]),
    do: {:mutate, {:set_tool, tool, permission}, confirm_flag?(rest)}

  defp policy_command(["remove", "deny", "path", pattern | rest]),
    do: {:mutate, {:remove_deny, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "allow-write", pattern | rest]),
    do: {:mutate, {:remove_allow_write, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "read-only", pattern | rest]),
    do: {:mutate, {:remove_read_only, pattern}, confirm_flag?(rest)}

  defp policy_command(["remove", "tool", tool | rest]),
    do: {:mutate, {:remove_tool, tool}, confirm_flag?(rest)}

  defp policy_command(_args) do
    {:error,
     "Malformed /policy command. Try /policy, /policy show, /policy init, /policy deny path <pattern>, or /policy tool <tool> allow|deny."}
  end

  defp mutate_policy(action, confirmed?) do
    old_policy = editable_policy()

    case apply_policy_action(old_policy, action) do
      {:ok, new_policy, label} ->
        if ProjectPolicy.weakening_change?(old_policy, new_policy) and not confirmed? do
          "Error: #{label} weakens project policy. Re-run with --confirm."
        else
          case ProjectPolicy.save(new_policy) do
            {:ok, saved} -> "Project policy updated: #{label}. #{ProjectPolicy.summary(saved)}"
            {:error, reason} -> "Error: cannot save project policy: #{inspect(reason)}"
          end
        end

      {:error, reason} ->
        "Error: #{reason}"
    end
  end

  defp reset_policy do
    path =
      Path.join(Beamcore.Agent.Tools.PathSafety.workspace_root(), ProjectPolicy.config_path())

    case File.rm(path) do
      :ok -> "Project policy reset. #{ProjectPolicy.summary(ProjectPolicy.load())}"
      {:error, :enoent} -> "Project policy reset. #{ProjectPolicy.summary(ProjectPolicy.load())}"
      {:error, reason} -> "Error: cannot reset project policy: #{reason}"
    end
  end

  defp editable_policy do
    case ProjectPolicy.load() do
      %{loaded?: true, valid?: true} = policy -> policy
      %{loaded?: false} -> ProjectPolicy.default()
      %{valid?: false, error: error} -> raise "Project policy is invalid: #{error}"
    end
  rescue
    error -> ProjectPolicy.default() |> Map.put(:error, Exception.message(error))
  end

  defp apply_policy_action(%{error: error}, _action) when is_binary(error),
    do: {:error, error}

  defp apply_policy_action(policy, {:add_deny, pattern}),
    do: {:ok, ProjectPolicy.add_deny_path(policy, pattern), "policy deny #{pattern}"}

  defp apply_policy_action(policy, {:add_allow_write, pattern}),
    do:
      {:ok, ProjectPolicy.add_allow_write_path(policy, pattern), "policy allow-write #{pattern}"}

  defp apply_policy_action(policy, {:add_read_only, pattern}),
    do: {:ok, ProjectPolicy.add_read_only_path(policy, pattern), "policy read-only #{pattern}"}

  defp apply_policy_action(policy, {:remove_deny, pattern}),
    do: {:ok, ProjectPolicy.remove_deny_path(policy, pattern), "policy remove deny #{pattern}"}

  defp apply_policy_action(policy, {:remove_allow_write, pattern}),
    do:
      {:ok, ProjectPolicy.remove_allow_write_path(policy, pattern),
       "policy remove allow-write #{pattern}"}

  defp apply_policy_action(policy, {:remove_read_only, pattern}),
    do:
      {:ok, ProjectPolicy.remove_read_only_path(policy, pattern),
       "policy remove read-only #{pattern}"}

  defp apply_policy_action(policy, {:set_tool, tool, permission}) do
    cond do
      tool not in ProjectPolicy.known_tools() ->
        {:error, "Unknown tool #{inspect(tool)}."}

      permission not in ProjectPolicy.permissions() ->
        {:error, "Unknown permission #{inspect(permission)}. Use allow or deny."}

      true ->
        {:ok, ProjectPolicy.set_tool_permission(policy, tool, permission),
         "policy tool #{tool} #{permission}"}
    end
  end

  defp apply_policy_action(policy, {:remove_tool, tool}) do
    if tool in ProjectPolicy.known_tools() do
      {:ok, ProjectPolicy.remove_tool_permission(policy, tool), "policy remove tool #{tool}"}
    else
      {:error, "Unknown tool #{inspect(tool)}."}
    end
  end

  defp confirm_flag?(args), do: "--confirm" in args

  defp handle_unknown(command, session, _output, false) do
    Beamcore.Agent.Core.Pretty.print_error("Unknown command: /#{command}")
    session
  end

  defp handle_unknown(command, session, output, true) do
    output.("Error: Unknown command: /#{command}")
    session
  end

  defp confirmed_execution_content(original_request, pending_action) do
    """
    Confirmed execution request.

    The user confirmed the pending plan. Execute it now using the Policy below.
    Do not call the plan tool. Do not ask for confirmation again.
    Use only the allowed tools and paths. Do not run validation tools unless they are listed in allowed_tools.
    If execution fails, report the error.

    #{policy_block(pending_action)}

    Original user request:
    #{String.trim(to_string(original_request))}
    """
    |> String.trim()
  end

  defp policy_block(pending_action) do
    policy = Map.get(pending_action, :policy, %{})

    allowed_write_paths =
      pending_action
      |> Map.get(:allowed_write_paths, Map.get(policy, :allowed_write_paths, []))
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    allowed_tools =
      policy
      |> Map.get(:allowed_tools, Map.get(pending_action, :allowed_tools, []))
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    blocked_tools =
      policy
      |> Map.get(:blocked_tools, [])
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()

    [
      "Policy:",
      "mode: restricted_write",
      list_block("allowed_write_paths", allowed_write_paths),
      list_block("allowed_tools", allowed_tools),
      list_block("blocked_tools", blocked_tools),
      "Task:",
      Map.get(pending_action, :summary, "Execute the confirmed pending plan.")
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == nil or &1 == ""))
    |> Enum.join("\n")
  end

  defp list_block(_key, []), do: []

  defp list_block(key, values) do
    ["#{key}:" | Enum.map(values, &"- #{&1}")]
  end
end
