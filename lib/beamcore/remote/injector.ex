defmodule Beamcore.Remote.Injector do
  @moduledoc """
  Pushes `Beamcore.RemoteRunner` onto an attached project node.

  The target node does not have BeamCore loaded, so before we can evaluate
  anything there we ship the runner's compiled object code across and load it
  with `:code.load_binary/3`. This keeps attach **zero-install** for the user:
  they never add a dependency; the agent injects the one module it needs.

  Injection is **idempotent and version-aware**. If the node already has a
  runner of the current `RemoteRunner.version/0`, we skip the transfer. If it has
  a stale version (an older agent attached earlier), we re-push.
  """

  alias Beamcore.RemoteRunner

  @runner RemoteRunner

  @doc """
  Ensure the current `RemoteRunner` is loaded on `node`.

  Returns `:ok` when the node ends up with a matching-version runner, or
  `{:error, reason}` if the object code is unavailable locally or the remote
  load fails.
  """
  @spec inject(node()) :: :ok | {:error, term()}
  def inject(node) when is_atom(node) do
    if remote_version(node) == RemoteRunner.version() do
      :ok
    else
      load(node)
    end
  end

  defp load(node) do
    with {:ok, binary, filename} <- object_code(),
         {:module, @runner} <- remote_load(node, filename, binary),
         true <- remote_version(node) == RemoteRunner.version() do
      :ok
    else
      :error -> {:error, :object_code_unavailable}
      {:error, reason} -> {:error, reason}
      {:badrpc, reason} -> {:error, {:badrpc, reason}}
      false -> {:error, :version_mismatch_after_load}
      other -> {:error, other}
    end
  end

  defp object_code do
    case :code.get_object_code(@runner) do
      {@runner, binary, filename} -> {:ok, binary, filename}
      :error -> :error
    end
  end

  defp remote_load(node, filename, binary) do
    :erpc.call(node, :code, :load_binary, [@runner, filename, binary])
  rescue
    e in ErlangError -> {:error, e.original}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # Returns the runner version loaded on `node`, or nil if the module isn't there
  # (or can't be reached). nil never equals a real version, so callers treat it
  # as "needs loading".
  defp remote_version(node) do
    :erpc.call(node, @runner, :version, [])
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
