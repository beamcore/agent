defmodule Beamcore.Remote do
  @moduledoc """
  Routes a prepared Eeva evaluation to an attached project node.

  `Beamcore.Agent.Tools.Eeva` calls `run/3` when `Beamcore.Remote.Session`
  reports an attached target. The prepared AST is evaluated on that node by the
  injected `Beamcore.RemoteRunner`, and the runner's status-tagged result is
  translated back into the same result tuples Eeva already formats for local
  execution, so the model-facing output is identical regardless of where the
  code ran.

  If the runner has gone missing on the node (e.g. it was purged, or the node
  restarted while still connected), `run/3` re-injects once and retries before
  giving up with `:remote_unavailable`.
  """

  alias Beamcore.Remote.Discovery
  alias Beamcore.Remote.Injector
  alias Beamcore.Remote.Session
  alias Beamcore.RemoteRunner

  @doc """
  Attach on boot if `BEAMCORE_TARGET_NODE` is set — the opt-in automation entry
  point. An optional `BEAMCORE_TARGET_COOKIE` is applied for cross-machine
  attach. Returns `:ignore` when unset, otherwise the `Session.attach/2` result.
  """
  @spec boot_attach() :: :ignore | :ok | {:error, term()}
  def boot_attach do
    case System.get_env("BEAMCORE_TARGET_NODE") do
      blank when blank in [nil, ""] -> :ignore
      name -> Session.attach(Discovery.resolve(name), boot_opts())
    end
  end

  defp boot_opts do
    case System.get_env("BEAMCORE_TARGET_COOKIE") do
      blank when blank in [nil, ""] -> []
      cookie -> [cookie: String.to_atom(cookie)]
    end
  end

  @doc """
  Startup hint messages for the TUI: a single nudge when project nodes are
  discoverable and we're not already attached. Empty otherwise, so it never
  appears when there's nothing to attach to. Never raises.
  """
  @spec attach_hint_messages() :: [%{role: :system, content: binary()}]
  def attach_hint_messages do
    if Session.attached?() do
      []
    else
      hint_for(safe_candidates())
    end
  end

  defp hint_for([]), do: []

  defp hint_for(nodes) do
    names = Enum.map_join(nodes, ", ", &Atom.to_string/1)

    [
      %{
        role: :system,
        content:
          "Detected project node(s): #{names}. Run /attach <name> to evaluate Eeva in that live runtime."
      }
    ]
  end

  defp safe_candidates do
    Discovery.candidates()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc """
  Evaluate `quoted` on `node` under `limits`, returning a local-style result.

  Returns one of:
    * `{:ok, %{status: :ok, output: binary, result: binary}}`
    * `{:remote_error, %{stdout: binary, stderr: binary, message: binary}}`
    * `{:error, kind, reason}` for limit/crash/transport failures
  """
  @spec run(node(), Macro.t(), map()) ::
          {:ok, map()} | {:remote_error, map()} | {:error, atom(), term()}
  def run(node, quoted, limits) when is_atom(node) and is_map(limits) do
    case call_runner(node, quoted, limits) do
      {:ok, result} ->
        translate(result)

      {:error, :not_loaded} ->
        reinject_and_retry(node, quoted, limits)

      {:error, reason} ->
        {:error, :remote_unavailable, reason}
    end
  end

  defp reinject_and_retry(node, quoted, limits) do
    case Injector.inject(node) do
      :ok ->
        case call_runner(node, quoted, limits) do
          {:ok, result} -> translate(result)
          {:error, reason} -> {:error, :remote_unavailable, reason}
        end

      {:error, reason} ->
        {:error, :remote_unavailable, {:inject_failed, reason}}
    end
  end

  defp call_runner(node, quoted, limits) do
    {:ok, :erpc.call(node, RemoteRunner, :run, [quoted, limits])}
  rescue
    e in ErlangError ->
      case e.original do
        {:exception, :undef, _stacktrace} -> {:error, :not_loaded}
        reason -> {:error, reason}
      end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp translate(%{status: :ok, stdout: stdout, result: result}) do
    {:ok, %{status: :ok, output: stdout, result: result}}
  end

  defp translate(%{status: :error, stdout: stdout, error: error, formatted: formatted}) do
    {:remote_error, %{stdout: stdout, stderr: formatted, message: error}}
  end

  defp translate(%{status: :timeout, timeout_ms: timeout_ms}) do
    {:error, :timeout, timeout_ms}
  end

  defp translate(%{status: :memory_limit, bytes: bytes}) do
    {:error, :memory_limit, bytes}
  end

  defp translate(%{status: :reduction_limit, reductions: reductions}) do
    {:error, :reduction_limit, reductions}
  end

  defp translate(%{status: :crash, reason: reason}) do
    {:error, :worker_exit, reason}
  end
end
