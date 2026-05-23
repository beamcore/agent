defmodule Beamcore.Agent.Chat.Commands do
  @moduledoc """
  Handles command parsing and execution.
  """

  alias Beamcore.Agent.Chat.Session
  alias Beamcore.Agent.Core.Pretty

  @doc """
  Handle a command and return the updated session.
  """
  def execute(command, session) do
    case command do
      "new" -> handle_new(session)
      "confirm" -> handle_confirm(session)
      "cancel" -> handle_cancel(session)
      "context" -> handle_context(session)
      "context clear" -> handle_context_clear(session)
      "help" -> handle_help(session)
      _ -> handle_unknown(command, session)
    end
  end

  defp handle_new(session) do
    IO.puts("Starting new session...")

    session.client
    |> Session.new()
    |> then(& &1)
  end

  defp handle_help(session) do
    IO.puts("""
    Available commands:
      /new  - Start a new chat session
      /confirm - Confirm the pending plan
      /cancel - Cancel the pending plan
      /context - Show compact session context
      /context clear - Clear compact session context
      /help - Show this help message
    """)

    session
  end

  defp handle_context(session) do
    IO.puts(Beamcore.Agent.Chat.Context.summary(session.context))
    session
  end

  defp handle_context_clear(session) do
    IO.puts("Session context cleared.")
    %{session | context: Beamcore.Agent.Chat.Context.new(session.project_nature)}
  end

  defp handle_confirm(%{context: %{pending_action: nil}} = session) do
    IO.puts("No pending action to confirm.")
    session
  end

  defp handle_confirm(%{pending_user_message: nil} = session) do
    IO.puts("No pending action to confirm.")
    session
  end

  defp handle_confirm(session) do
    pending_action = session.context.pending_action
    confirmed_content = confirmed_execution_content(session.pending_user_message, pending_action)
    confirmed_session = Session.clear_pending_action(session)

    IO.puts("Confirmed pending action.")
    {:run_pending, confirmed_session, confirmed_content, pending_action.policy}
  end

  defp handle_cancel(%{context: %{pending_action: nil}} = session) do
    IO.puts("No pending action to cancel.")
    session
  end

  defp handle_cancel(session) do
    IO.puts("Pending action canceled.")
    Session.clear_pending_action(session)
  end

  defp handle_unknown(command, session) do
    Pretty.print_error("Unknown command: /#{command}")
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
