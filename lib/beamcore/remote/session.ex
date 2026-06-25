defmodule Beamcore.Remote.Session do
  @moduledoc """
  Owns the agent's attach state to a project node.

  When **detached** (the default), Eeva evaluates locally in BeamCore's own VM,
  exactly as before. When **attached** to a node, the prepared AST is routed to
  that node (see `Beamcore.Remote`), so the project's modules, deps and running
  applications are in scope.

  Attaching is always an explicit act — a `/attach` command or an opt-in env var.
  Nothing connects on its own. The session monitors the attached node and
  **auto-detaches** if it goes down, so a dropped connection degrades cleanly
  back to local eval instead of leaving a stale target.

  `target/0` is the hot-path read used by Eeva on every tool call. It reads from
  `:persistent_term` rather than calling this GenServer, so a busy session never
  blocks or serializes eval routing.
  """

  use GenServer

  require Logger

  alias Beamcore.Remote.Injector

  @target_key {__MODULE__, :target}

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Attach to `node`, connecting and injecting the runner.

  Options:
    * `:cookie` — set a per-node magic cookie before connecting (cross-machine).

  Returns `:ok` or `{:error, reason}` (`:not_distributed`, `:cannot_attach_to_self`,
  `:connect_failed`, or an injection error).
  """
  @spec attach(node(), keyword()) :: :ok | {:error, term()}
  def attach(node, opts \\ []) when is_atom(node) and is_list(opts) do
    GenServer.call(__MODULE__, {:attach, node, opts}, 30_000)
  end

  @doc "Detach and return to local eval. Always succeeds."
  @spec detach() :: :ok
  def detach, do: GenServer.call(__MODULE__, :detach)

  @doc """
  Current routing target, read straight from `:persistent_term`.

  `:local` when detached, `{:attached, node}` when attached.
  """
  @spec target() :: :local | {:attached, node()}
  def target, do: :persistent_term.get(@target_key, :local)

  @doc "Full status map for the UI: `%{status: ..., node: ...}`."
  @spec status() :: %{status: atom(), node: node() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @doc "Whether the agent is currently attached to a project node."
  @spec attached?() :: boolean()
  def attached? do
    case target() do
      {:attached, _node} -> true
      :local -> false
    end
  end

  # --- Server ---

  @impl true
  def init(_opts) do
    :persistent_term.put(@target_key, :local)
    {:ok, %{status: :detached, node: nil}}
  end

  @impl true
  def handle_call({:attach, node, opts}, _from, state) do
    case do_attach(node, opts) do
      :ok ->
        Node.monitor(node, true)
        :persistent_term.put(@target_key, {:attached, node})
        Logger.info("[Remote] Attached to #{inspect(node)}")
        {:reply, :ok, %{state | status: :attached, node: node}}

      {:error, reason} = error ->
        {:reply, error, clear(state, reason)}
    end
  end

  def handle_call(:detach, _from, state) do
    {:reply, :ok, do_detach(state)}
  end

  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, node: state.node}, state}
  end

  @impl true
  def handle_info({:nodedown, node}, %{node: node} = state) do
    Logger.warning("[Remote] Attached node #{inspect(node)} went down; detaching")
    {:noreply, do_detach(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # --- Internal ---

  defp do_attach(node, _opts) when node == node(), do: {:error, :cannot_attach_to_self}

  defp do_attach(node, opts) do
    if Node.alive?() do
      maybe_set_cookie(node, Keyword.get(opts, :cookie))
      connect_and_inject(node)
    else
      {:error, :not_distributed}
    end
  end

  defp connect_and_inject(node) do
    case Node.connect(node) do
      true -> Injector.inject(node)
      _ -> {:error, :connect_failed}
    end
  end

  defp maybe_set_cookie(_node, nil), do: :ok
  defp maybe_set_cookie(node, cookie) when is_atom(cookie), do: Node.set_cookie(node, cookie)

  defp do_detach(%{node: nil} = state) do
    :persistent_term.put(@target_key, :local)
    %{state | status: :detached}
  end

  defp do_detach(%{node: node} = state) do
    Node.monitor(node, false)
    :persistent_term.put(@target_key, :local)
    %{state | status: :detached, node: nil}
  end

  # On a failed attach we stay/return detached rather than half-attached.
  defp clear(state, _reason) do
    :persistent_term.put(@target_key, :local)
    %{state | status: :detached, node: nil}
  end
end
