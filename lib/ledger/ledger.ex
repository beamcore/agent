defmodule Beamcore.Ledger do
  @moduledoc """
  Ledger service acts as an action journal and metric exporter for agent tool operations.
  Can be run locally as part of the agent's supervision tree, or run standalone and shared.
  """

  use GenServer

  @default_log_path "~/.beamcore/ledger.jsonl"

  # --- Client API ---

  @doc """
  Starts the Ledger GenServer.

  Supported options:
    - `:global` (boolean) - if true, registers the process globally as `{:global, Beamcore.Ledger}`
    - `:log_path` (string) - custom log file path
  """
  def start_link(opts \\ []) do
    name =
      if opts[:global] || System.get_env("LEDGER_GLOBAL") == "true" do
        {:global, __MODULE__}
      else
        __MODULE__
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Logs a tool execution to the ledger.
  Resiliently attempts to find a global or local ledger, falling back to a direct file log
  if no process is currently active.
  """
  def log_action(org, repo, tool, args, result, duration, tokens \\ 0, status \\ :ok) do
    tokens =
      if tokens == 0 or is_nil(tokens) do
        estimate_tokens(result)
      else
        tokens
      end

    case server_ref() do
      nil ->
        # Fallback logging if the GenServer is not running or available
        fallback_log(org, repo, tool, args, result, duration, tokens, status)

      ref ->
        GenServer.cast(
          ref,
          {:log_action, org, repo, tool, args, result, duration, tokens, status}
        )
    end
  end

  @doc """
  Retrieves a map of all logged metrics.
  """
  def get_metrics do
    if :ets.info(:beamcore_ledger_metrics) == :undefined do
      %{}
    else
      :ets.tab2list(:beamcore_ledger_metrics)
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case key do
          {metric, org, repo, tool} ->
            Map.put(acc, {org, repo, tool, metric}, value)

          _ ->
            acc
        end
      end)
    end
  end

  @doc """
  Exports the current metrics in the Prometheus exposition text format.
  """
  def export_prometheus do
    metrics = get_metrics()

    groups =
      Enum.group_by(metrics, fn {{org, repo, tool, _metric}, _val} ->
        {org, repo, tool}
      end)

    header = """
    # HELP agent_actions_total Total number of actions executed by the agent
    # TYPE agent_actions_total counter
    # HELP agent_action_duration Total duration of action executions in milliseconds
    # TYPE agent_action_duration counter
    # HELP agent_tokens_total Total tokens consumed during action executions
    # TYPE agent_tokens_total counter
    # HELP agent_errors_total Total number of failed or error actions
    # TYPE agent_errors_total counter
    """

    lines =
      Enum.map(groups, fn {{org, repo, tool}, values} ->
        actions = find_metric_value(values, :actions)
        duration = find_metric_value(values, :duration)
        tokens = find_metric_value(values, :tokens)
        errors = find_metric_value(values, :errors)

        labels = ~s(org="#{org}",repo="#{repo}",tool="#{tool}")

        [
          "agent_actions_total{#{labels}} #{actions}",
          "agent_action_duration{#{labels}} #{duration}",
          "agent_tokens_total{#{labels}} #{tokens}",
          "agent_errors_total{#{labels}} #{errors}"
        ]
      end)
      |> List.flatten()
      |> Enum.join("\n")

    if lines == "" do
      header
    else
      header <> lines <> "\n"
    end
  end

  @doc """
  Clears the in-memory metrics and GenServer state.
  """
  def clear do
    case server_ref() do
      nil ->
        if :ets.info(:beamcore_ledger_metrics) != :undefined do
          :ets.delete_all_objects(:beamcore_ledger_metrics)
        end

        :ok

      ref ->
        GenServer.call(ref, :clear)
    end
  end

  @doc """
  Detects the organization and repository name dynamically using Git remote URL
  or environment variable overrides (`BEAMCORE_ORG`, `BEAMCORE_REPO`).
  """
  def detect_org_repo do
    env_org = System.get_env("BEAMCORE_ORG")
    env_repo = System.get_env("BEAMCORE_REPO")

    if env_org && env_repo do
      {env_org, env_repo}
    else
      case System.cmd("git", ["config", "--get", "remote.origin.url"]) do
        {url, 0} ->
          url = String.trim(url)

          case parse_git_url(url) do
            {org, repo} -> {org, repo}
            nil -> {"default_org", "default_repo"}
          end

        _ ->
          {"default_org", "default_repo"}
      end
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    # Create public ETS table so reads are super fast and concurrent
    if :ets.info(:beamcore_ledger_metrics) == :undefined do
      :ets.new(:beamcore_ledger_metrics, [:set, :public, :named_table])
    end

    log_path = opts[:log_path] || System.get_env("LEDGER_LOG_PATH") || @default_log_path
    expanded_path = Path.expand(log_path)

    # Ensure log directory exists
    File.mkdir_p!(Path.dirname(expanded_path))

    state = %{
      log_path: log_path,
      expanded_path: expanded_path
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    if :ets.info(:beamcore_ledger_metrics) != :undefined do
      :ets.delete_all_objects(:beamcore_ledger_metrics)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(
        {:log_action, org, repo, tool, args, result, duration, tokens, status},
        state
      ) do
    # 1. Update ETS metrics
    update_ets_metrics(org, repo, tool, duration, tokens, status)

    # 2. Write to log file
    write_log_line(state.expanded_path, org, repo, tool, args, result, duration, tokens, status)

    {:noreply, state}
  end

  # --- Helper functions ---

  defp server_ref do
    cond do
      GenServer.whereis({:global, __MODULE__}) -> {:global, __MODULE__}
      GenServer.whereis(__MODULE__) -> __MODULE__
      true -> nil
    end
  end

  defp fallback_log(org, repo, tool, args, result, duration, tokens, status) do
    # Fallback updates the ETS table if it exists
    if :ets.info(:beamcore_ledger_metrics) != :undefined do
      update_ets_metrics(org, repo, tool, duration, tokens, status)
    end

    log_path = System.get_env("LEDGER_LOG_PATH") || @default_log_path
    expanded_path = Path.expand(log_path)

    try do
      File.mkdir_p!(Path.dirname(expanded_path))
      write_log_line(expanded_path, org, repo, tool, args, result, duration, tokens, status)
    rescue
      _ ->
        # Silently absorb disk errors on fallback to prevent crashing the agent
        :ok
    end
  end

  defp update_ets_metrics(org, repo, tool, duration, tokens, status) do
    # Actions
    :ets.update_counter(
      :beamcore_ledger_metrics,
      {:actions, org, repo, tool},
      1,
      {{:actions, org, repo, tool}, 0}
    )

    # Duration
    :ets.update_counter(
      :beamcore_ledger_metrics,
      {:duration, org, repo, tool},
      duration,
      {{:duration, org, repo, tool}, 0}
    )

    # Tokens
    if tokens > 0 do
      :ets.update_counter(
        :beamcore_ledger_metrics,
        {:tokens, org, repo, tool},
        tokens,
        {{:tokens, org, repo, tool}, 0}
      )
    end

    # Errors
    if status == :error do
      :ets.update_counter(
        :beamcore_ledger_metrics,
        {:errors, org, repo, tool},
        1,
        {{:errors, org, repo, tool}, 0}
      )
    end
  end

  defp write_log_line(file_path, org, repo, tool, args, result, duration, tokens, status) do
    record = %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      org: org,
      repo: repo,
      tool: tool,
      args: args,
      result: summarize_result(result),
      duration_ms: duration,
      tokens: tokens,
      status: to_string(status)
    }

    case Jason.encode(record) do
      {:ok, json} ->
        File.write!(file_path, json <> "\n", [:append])

      _ ->
        :ok
    end
  end

  defp summarize_result(result) when is_binary(result), do: result

  defp summarize_result(result), do: inspect(result, limit: :infinity)

  defp parse_git_url(url) do
    url = String.replace_suffix(url, ".git", "")
    parts = String.split(url, [":", "/"])

    case Enum.reverse(parts) do
      [repo, org | _] -> {org, repo}
      _ -> nil
    end
  end

  defp find_metric_value(values, target_metric) do
    case Enum.find(values, fn {{_, _, _, metric}, _} -> metric == target_metric end) do
      {_, val} -> val
      nil -> 0
    end
  end

  defp estimate_tokens(result) when is_binary(result) do
    round(String.length(result) / 4)
  end

  defp estimate_tokens(result) do
    round(String.length(inspect(result)) / 4)
  end
end
