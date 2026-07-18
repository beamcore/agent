defmodule Beamcore.Agent.Chat.Session.Restore do
  @moduledoc """
  Restores a session from its log file.

  Parses clean session logs where each line is a message (user, assistant, tool, system)
  or a metadata header. Reconstructs a Session struct ready for the TUI.
  """

  @session_dir Path.join([System.user_home!(), ".agent", "sessions"])

  @doc """
  Builds a session from the log file for the given session name.

  Returns a `%Session{}` with messages populated, ready for the TUI to display.
  The log file path is preserved so new messages append to the same file.
  """
  def build(session_name) do
    path = Path.join(@session_dir, "#{session_name}.json")

    unless File.exists?(path) do
      raise "Session '#{session_name}' not found at #{path}"
    end

    {meta, messages} = parse_file(path)

    workspace_root =
      meta[:workspace] || meta["workspace"] ||
        Beamcore.Agent.Tools.PathInput.workspace_root()

    mode_settings = resolve_mode_settings(meta)

    roles = %Beamcore.Provider.Selection{
      primary: %{
        provider: mode_settings.provider,
        model: mode_settings.model,
        enabled: true
      },
      fallback: nil
    }

    %Beamcore.Agent.Chat.Session{
      session_id: session_name,
      messages: messages,
      log_file: path,
      client: nil,
      roles: roles,
      mode_settings: mode_settings,
      workspace_root: workspace_root,
      compaction_count: meta[:compaction_count] || 0,
      total_prompt_tokens: 0,
      total_completion_tokens: 0,
      total_tokens: 0,
      total_cached_tokens: 0,
      last_prompt_tokens: 0,
      screen_type: :agent
    }
  end

  @doc """
  Lists all available sessions sorted by modification time (newest first).

  Returns a list of `{name, mtime, size}` tuples.
  """
  def list do
    unless File.dir?(@session_dir) do
      []
    else
      @session_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.reject(&String.contains?(&1, ".state.json"))
      |> Enum.reject(&String.contains?(&1, ".checkpoints.json"))
      |> Enum.map(fn file ->
        name = String.replace_suffix(file, ".json", "")
        stat = File.stat!(Path.join(@session_dir, file))
        {name, stat.mtime, stat.size}
      end)
      |> Enum.sort_by(fn {_, mtime, _} -> mtime end, :desc)
    end
  end

  # --- Private ---

  defp parse_file(path) do
    lines =
      File.read!(path)
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))

    {meta, messages} =
      Enum.reduce(lines, {nil, []}, fn line, {meta, msgs} ->
        case Jason.decode(line) do
          {:ok, %{"_meta" => true} = m} ->
            {atomize_meta(m), msgs}

          {:ok, %{"role" => role} = msg} when role in ["system", "user", "assistant", "tool"] ->
            {meta, msgs ++ [ensure_string_keys(msg)]}

          _ ->
            {meta, msgs}
        end
      end)

    # Deduplicate system prompts: keep the first one only
    {system_msgs, rest} = Enum.split_with(messages, &(&1["role"] == "system"))

    messages =
      case system_msgs do
        [first | _] -> [first | rest]
        [] -> rest
      end

    {meta, messages}
  end

  defp atomize_meta(map) do
    Map.new(map, fn
      {"_meta", v} -> {:_meta, v}
      {"session_id", v} -> {:session_id, v}
      {"provider", v} -> {:provider, v}
      {"model", v} -> {:model, v}
      {"created_at", v} -> {:created_at, v}
      {"workspace", v} -> {:workspace, v}
      {"compaction_count", v} -> {:compaction_count, v}
      {k, v} -> {k, v}
    end)
  end

  defp ensure_string_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp ensure_string_keys(other), do: other

  defp resolve_mode_settings(%{provider: p, model: m}) when is_binary(p) and is_binary(m) do
    %Beamcore.Agent.Chat.ModeSettings{
      mode: :agent,
      provider: p,
      model: m
    }
  end

  defp resolve_mode_settings(_) do
    Beamcore.Agent.Chat.ModeSettings.resolve(:agent)
  end
end
