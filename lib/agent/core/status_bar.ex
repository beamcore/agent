defmodule Beamcore.Agent.Core.StatusBar do
  @moduledoc """
  Manages a persistent status bar at the bottom of the terminal.

  This module uses a `GenServer` to manage terminal state, including the scrolling
  region and cursor position. It supports ANSI-compatible terminals and provides
  a fallback for non-ANSI environments.

  ## Features
  - Dynamic terminal size detection and caching.
  - Debounced updates to prevent excessive terminal I/O.
  - ANSI escape sequence abstraction for readability.
  - Automatic cleanup on crashes or shutdown.

  ## Usage
  Start the `StatusBar` process:
      {:ok, pid} = Beamcore.Agent.Core.StatusBar.start_link()

  Update the status bar with session data:
      Beamcore.Agent.Core.StatusBar.update(pid, session)

  Reset the terminal state:
      Beamcore.Agent.Core.StatusBar.reset(pid)
  """

  use GenServer

  alias Beamcore.Agent.Core.ANSI
  alias Beamcore.Agent.Chat.Session
  alias Number.SI, as: SI

  # Maximum updates per second (100ms interval)
  @debounce_interval 100

  @doc """
  Starts the `StatusBar` GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Updates the status bar with the provided session data.

  This function is debounced to prevent excessive terminal updates.
  """
  def update(pid, session) do
    GenServer.cast(pid, {:update, session})
  end

  @doc """
  Updates the status bar with custom text immediately.
  """
  def update_text(pid, text) do
    GenServer.cast(pid, {:update_text, text})
  end

  @doc """
  Resets the terminal scrolling region to full screen.
  """
  def reset(pid) do
    GenServer.cast(pid, :reset)
  end

  @doc """
  Sets up the terminal scrolling region to reserve the bottom line for the status bar.
  """
  def setup(pid) do
    GenServer.cast(pid, :setup)
  end

  @impl true
  def init(opts) do
    state = %{
      terminal_size: get_terminal_size(),
      last_update: nil,
      pending_update: nil,
      ansi_supported: Keyword.get(opts, :ansi_supported, check_ansi_support()),
      opts: opts
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:update, session}, state) do
    current_time = System.system_time(:millisecond)
    last_update = state.last_update

    # Debounce logic: Skip if last update was within the debounce interval
    if last_update && current_time - last_update < @debounce_interval do
      # Store the pending update to be processed later
      {:noreply, %{state | pending_update: {:update, session}}}
    else
      # Process the update immediately
      do_update(session, state)
    end
  end

  @impl true
  def handle_cast({:update_text, text}, state) do
    do_update_text(text, state)
  end

  @impl true
  def handle_cast(:reset, state) do
    if state.ansi_supported do
      IO.write(ANSI.reset_scroll())
    end

    {:noreply, %{state | pending_update: nil}}
  end

  @impl true
  def handle_cast(:setup, state) do
    if state.ansi_supported do
      {rows, cols} = state.terminal_size
      IO.write(ANSI.set_scroll_region(1, rows - 1))
      IO.write(ANSI.move_to_row(rows))
      IO.write(String.duplicate(" ", cols))
      IO.write(ANSI.move_to_row(rows - 1))
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:check_pending_update, state) do
    case state.pending_update do
      nil ->
        {:noreply, state}

      {:update, session} ->
        do_update(session, %{state | pending_update: nil})
    end
  end

  defp do_update(session, state) do
    current_time = System.system_time(:millisecond)

    if state.ansi_supported do
      {rows, cols} = state.terminal_size
      usage = Session.usage(session)

      # Format token counts using SI notation
      total_tokens = SI.number_to_si(usage.total_tokens, precision: 1, trim: true)
      prompt_tokens = SI.number_to_si(usage.prompt_tokens, precision: 1, trim: true)
      completion_tokens = SI.number_to_si(usage.completion_tokens, precision: 1, trim: true)

      status_text =
        " 📊 Tokens: #{total_tokens} (P: #{prompt_tokens}, C: #{completion_tokens}) | 🆔 Session: #{session.session_id} "

      # Truncate if too long
      status_text =
        if String.length(status_text) > cols do
          String.slice(status_text, 0, cols - 3) <> "..."
        else
          status_text
        end

      # Build the formatted status bar output
      formatted_status =
        ANSI.save_cursor() <>
          ANSI.move_to_row(rows) <>
          ANSI.clear_line() <>
          ANSI.status_bar_style() <>
          String.pad_trailing(status_text, cols) <>
          ANSI.reset_style() <>
          ANSI.restore_cursor()

      IO.write(formatted_status)
    else
      # Non-ANSI fallback: Print status as plain text
      usage = Session.usage(session)

      IO.puts(
        "[Status] Tokens: #{usage.total_tokens} (P: #{usage.prompt_tokens}, C: #{usage.completion_tokens}) | Session: #{session.session_id}"
      )
    end

    # Schedule a check for pending updates after the debounce interval
    Process.send_after(self(), :check_pending_update, @debounce_interval)

    {:noreply, %{state | last_update: current_time, pending_update: nil}}
  end

  defp do_update_text(text, state) do
    if state.ansi_supported do
      {rows, cols} = state.terminal_size

      status_text =
        if String.length(text) > cols do
          String.slice(text, 0, cols - 3) <> "..."
        else
          text
        end

      formatted_status =
        ANSI.save_cursor() <>
          ANSI.move_to_row(rows) <>
          ANSI.clear_line() <>
          ANSI.status_bar_style() <>
          String.pad_trailing(status_text, cols) <>
          ANSI.reset_style() <>
          ANSI.restore_cursor()

      IO.write(formatted_status)
    else
      IO.puts("[Status] #{text}")
    end

    {:noreply, state}
  end

  # Retrieves the current terminal size (rows, columns).
  #
  # Falls back to {24, 80} if the terminal size cannot be determined.
  def get_terminal_size do
    with {:ok, rows} <- :io.rows(),
         {:ok, cols} <- :io.columns() do
      {rows, cols}
    else
      _ ->
        case System.cmd("stty", ["size"], stderr_to_stdout: true) do
          {output, 0} ->
            parts = output |> String.trim() |> String.split()

            case parts do
              [rows, cols] -> {String.to_integer(rows), String.to_integer(cols)}
              _ -> {24, 80}
            end

          _ ->
            {24, 80}
        end
    end
  end

  # Checks if the terminal supports ANSI escape sequences.
  #
  # Assumes ANSI support if the TERM environment variable is not 'dumb'.
  defp check_ansi_support do
    case System.get_env("TERM") do
      "dumb" -> false
      _ -> true
    end
  end
end
