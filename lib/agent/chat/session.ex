defmodule Beamcore.Agent.Chat.Session do
  @moduledoc """
  Manages chat sessions and persists them to disk.
  """

  defstruct [
    :messages,
    :client,
    :session_id,
    :log_file,
    :total_prompt_tokens,
    :total_completion_tokens,
    :total_tokens,
    :project_nature
  ]

  @colors ~w(red blue green yellow purple orange pink brown black white gray cyan magenta lime maroon navy olive teal silver gold)
  @animals ~w(cat dog bird fish elephant lion tiger bear wolf fox owl hawk eagle shark whale dolphin octopus spider snake frog)
  @qualities ~w(hairy slimy fluffy scaly shiny bumpy soft hard fast slow loud quiet smart silly funny brave shy happy sad angry)

  @doc """
  Generates a funny session name in the format "color-property-animal".
  """
  def generate_name() do
    "#{Enum.random(@colors)}-#{Enum.random(@qualities)}-#{Enum.random(@animals)}"
  end

  @doc """
  Creates a new session and initializes the log file.
  """
  def new(client) do
    session_id = generate_name()
    log_dir = Path.join([System.user_home!(), ".agent", "sessions"])
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "#{session_id}.json")

    project_nature = Beamcore.Agent.Discovery.Detector.detect()

    system_message = %{
      role: "system",
      content: Beamcore.Agent.Core.SysPrompt.generate(project_nature)
    }

    %__MODULE__{
      messages: [system_message],
      client: client,
      session_id: session_id,
      log_file: log_file,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      project_nature: project_nature
    }
    |> then(&log(&1, system_message))
  end

  @doc """
  Logs data to the session file in JSON format.
  """
  def log(session, data) do
    json = Jason.encode!(data)
    File.write!(session.log_file, json <> "\n", [:append])
    session
  end

  @doc """
  Updates the session's token usage with the usage data from an API response.

  Expected usage format:
  %{
    "completion_tokens" => integer(),
    "prompt_tokens" => integer(),
    "total_tokens" => integer()
  }
  """
  def update_usage(session, usage) do
    %{
      session
      | total_prompt_tokens: session.total_prompt_tokens + usage["prompt_tokens"],
        total_completion_tokens: session.total_completion_tokens + usage["completion_tokens"],
        total_tokens: session.total_tokens + usage["total_tokens"]
    }
  end

  @doc """
  Returns the current token usage for the session.

  Returns a map with:
  - :prompt_tokens - Total prompt tokens used.
  - :completion_tokens - Total completion tokens used.
  - :total_tokens - Total tokens used (prompt + completion).
  """
  def usage(session) do
    %{
      prompt_tokens: session.total_prompt_tokens,
      completion_tokens: session.total_completion_tokens,
      total_tokens: session.total_tokens
    }
  end

  @doc """
  Summarizes the current session context and rolls over into a new session.
  """
  def summarize_and_rollover(session, messages, pid) do
    Beamcore.Agent.Core.Pretty.print_warning(
      "Token limit approaching. Summarizing and rolling over to a new session..."
    )

    Beamcore.Agent.Core.StatusBar.update_text(
      pid,
      " ⚠️  ROLLING OVER SESSION (Summarizing context...) "
    )

    summary_prompt = %{
      role: "user",
      content:
        "We are approaching the context limit. Please summarize the progress we've made so far, key decisions, the current state of the codebase, and what needs to be done next. This summary will be used to seed our next session so we can continue seamlessly."
    }

    temp_messages = messages ++ [summary_prompt]

    case Beamcore.Agent.Chat.API.execute(session.client, temp_messages, [], :main) do
      {:ok, %{message: %{"content" => summary}}} ->
        # Validate the summary content
        default_summary =
          "Previous session summary was empty or invalid. Continuing with a fresh session."

        validated_summary =
          if summary && is_binary(summary) && String.length(summary) > 0 &&
               String.length(summary) <= 10_000 do
            summary
          else
            default_summary
          end

        new_session = new(session.client)

        # Explicitly reset token counters for the new session
        new_session = %{
          new_session
          | total_prompt_tokens: 0,
            total_completion_tokens: 0,
            total_tokens: 0
        }

        # Extract the original system message
        [%{role: "system", content: original_system_message}] = new_session.messages

        # Create a combined system message with the original prompt and summary
        combined_system_message = %{
          role: "system",
          content:
            "System: #{original_system_message}\n\nPrevious Session Summary:\n#{validated_summary}"
        }

        # Replace the system message in the new session
        new_session = %{new_session | messages: [combined_system_message]}

        # Log the combined system message to the new session
        log(new_session, combined_system_message)

        Beamcore.Agent.Core.StatusBar.update(pid, new_session)

        Beamcore.Agent.Core.Pretty.print_assistant(
          "Session rolled over successfully. New session ID: #{new_session.session_id}",
          :main
        )

        new_session

      {:error, reason} ->
        Beamcore.Agent.Core.Pretty.print_error("Failed to summarize session: #{inspect(reason)}")
        # If it fails, return the old session
        %{session | messages: messages}
    end
  end
end
