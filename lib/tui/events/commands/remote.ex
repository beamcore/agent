defmodule Beamcore.TUI.Events.Commands.Remote do
  @moduledoc """
  `/attach` and `/detach` command handlers.

  Wires the TUI to `Beamcore.Remote.Session`: attaching routes Eeva eval into a
  project node's live runtime, detaching returns to local eval. Every outcome
  reports back to the user as a system message.
  """

  alias Beamcore.Remote.Discovery
  alias Beamcore.Remote.Session
  alias Beamcore.TUI.State

  @doc "Handle `/attach` (no name lists candidates) and `/attach <name>`."
  def attach(state, "") do
    case Discovery.candidates() do
      [] ->
        State.add_message(
          state,
          :system,
          "No project nodes found on epmd. Start your app as a named node " <>
            "(e.g. iex --sname myapp -S mix), then run /attach <name>."
        )

      nodes ->
        listing = Enum.map_join(nodes, "\n", &"  - #{&1}")

        State.add_message(
          state,
          :system,
          "Project nodes found:\n#{listing}\n\nRun /attach <name> to go live."
        )
    end
  end

  def attach(state, name) do
    node = Discovery.resolve(name)

    case Session.attach(node) do
      :ok ->
        State.add_message(
          state,
          :system,
          "Attached to #{node}. Eeva now evaluates in that runtime — /detach to return."
        )

      {:error, reason} ->
        State.add_message(state, :system, "Could not attach to #{node}: #{describe(reason)}")
    end
  end

  @doc "Handle `/detach`."
  def detach(state) do
    case Session.target() do
      :local ->
        State.add_message(state, :system, "Not attached — Eeva is already running locally.")

      {:attached, node} ->
        Session.detach()
        State.add_message(state, :system, "Detached from #{node}. Eeva runs locally again.")
    end
  end

  defp describe(:not_distributed),
    do: "this agent isn't a distributed node — start it with a node name"

  defp describe(:connect_failed),
    do: "couldn't connect (is it running and named? do the cookies match?)"

  defp describe(:cannot_attach_to_self), do: "that's this agent's own node"
  defp describe({:badrpc, reason}), do: "remote call failed (#{inspect(reason)})"
  defp describe({:inject_failed, reason}), do: "runner injection failed (#{inspect(reason)})"
  defp describe(reason), do: inspect(reason)
end
