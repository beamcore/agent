defmodule Beamcore.Agent.Core.Pretty do
  @moduledoc "
  Module for pretty-printing and formatting chat responses, tool calls, and errors.
  Supports colored output, structured formatting, and customizable themes.
    "

  defmodule Colors do
    @moduledoc "ANSI color codes for terminal output."

    @doc "Reset all stats"
    def reset, do: "\e[0m"

    @doc "Bold text."
    def bold, do: "\e[1m"

    @doc "Dim text."
    def dim, do: "\e[2m"

    @doc "Italic text."
    def italic, do: "\e[3m"

    @doc "Underline text."
    def underline, do: "\e[4m"

    @doc "Black text."
    def black, do: "\e[30m"

    @doc "Red text."
    def red, do: "\e[31m"

    @doc "Green text."
    def green, do: "\e[32m"

    @doc "Yellow text."
    def yellow, do: "\e[33m"

    @doc "Blue text."
    def blue, do: "\e[34m"

    @doc "Magenta text."
    def magenta, do: "\e[35m"

    @doc "Cyan text."
    def cyan, do: "\e[36m"

    @doc "White text."
    def white, do: "\e[37m"

    @doc "Bright black text."
    def bright_black, do: "\e[90m"

    @doc "Bright red text."
    def bright_red, do: "\e[91m"

    @doc "Bright green text.  "
    def bright_green, do: "\e[92m"

    @doc "Bright yellow text. "
    def bright_yellow, do: "\e[93m"

    @doc "Bright blue text. "
    def bright_blue, do: "\e[94m"

    @doc "Bright magenta text.  "
    def bright_magenta, do: "\e[95m"

    @doc "Bright cyan text. "
    def bright_cyan, do: "\e[96m"

    @doc "Bright white text.  "
    def bright_white, do: "\e[97m"

    @doc "Background black. "
    def bg_black, do: "\e[40m"

    @doc "Background red. "
    def bg_red, do: "\e[41m"

    @doc "Background green. "
    def bg_green, do: "\e[42m"

    @doc "Background yellow.  "
    def bg_yellow, do: "\e[43m"

    @doc "Background blue.  "
    def bg_blue, do: "\e[44m"

    @doc "Background magenta. "
    def bg_magenta, do: "\e[45m"

    @doc "Background cyan.  "
    def bg_cyan, do: "\e[46m"

    @doc "Background white. "
    def bg_white, do: "\e[47m"
  end

  @doc "
  Check if the terminal supports ANSI colors.
    "
  def supports_color? do
    case System.get_env("NO_COLOR") do
      "true" -> false
      _ -> true
    end
  end

  @doc "
  Apply ANSI color to text if colors are supported.
    "
  def colorize(text, color \\ &Colors.cyan/0) when is_function(color) do
    colorize(text, color, supports_color?())
  end

  def colorize(text, color, enabled?) when is_function(color) and is_boolean(enabled?) do
    if enabled? do
      color_code = color.()
      "#{color_code}#{text}#{Colors.reset()}"
    else
      text
    end
  end

  @doc "
  Print a horizontal separator line.
    "
  def separator(length \\ 80) do
    colorize(String.duplicate("─", length), &Colors.dim/0)
  end

  @doc "
  Wrap text in a visual box.
    "
  def box(text, title \\ nil, color \\ &Colors.cyan/0) do
    lines = String.split(text, "\n")
    max_length = max(3, Enum.map(lines, &String.length/1) |> Enum.max())

    if title do
      title_line = " ┌" <> String.duplicate("─", max_length + 2) <> "┐"
      title_padding = max(0, max_length - String.length(title) - 2)
      title_text = " │ " <> colorize(title, color) <> String.duplicate(" ", title_padding) <> " │"
      separator_line = " ├" <> String.duplicate("─", max_length + 2) <> "┤"

      content_lines =
        Enum.map(lines, fn line ->
          padding = String.duplicate(" ", max_length - String.length(line))
          " │ #{line}#{padding} │"
        end)

      footer_line = " └" <> String.duplicate("─", max_length + 2) <> "┘"

      [title_line, title_text, separator_line] ++ content_lines ++ [footer_line]
    else
      top_line = "┌" <> String.duplicate("─", max_length + 2) <> "┐"

      content_lines =
        Enum.map(lines, fn line ->
          padding = String.duplicate(" ", max_length - String.length(line))
          "│ #{line}#{padding} │"
        end)

      bottom_line = "└" <> String.duplicate("─", max_length + 2) <> "┘"

      [top_line] ++ content_lines ++ [bottom_line]
    end
    |> Enum.join("\n")
    |> IO.puts()
  end

  @doc "
  Print the user input prompt.
    "
  def print_prompt do
    IO.write("\n" <> colorize("> ", &Colors.bright_green/0))
  end

  @doc "
  Print the assistant's response.
    "
  def print_assistant(content, context \\ :main)

  def print_assistant(content, context) when is_binary(content) and content != "" do
    prefix = get_prefix(context)
    color = get_assistant_color(context)
    IO.puts("\n" <> colorize(prefix, color) <> content)
  end

  def print_assistant(_, _), do: :ok

  @doc "
  Print the assistant's thinking content.
    "
  def print_thinking(content, context \\ :main)

  def print_thinking(content, context) when is_binary(content) and content != "" do
    prefix = get_prefix(context)
    color = get_thinking_color(context)
    IO.puts("\n" <> colorize(prefix, color) <> content)
  end

  def print_thinking(_, _), do: :ok

  @doc "
  Print a tool call.
    "
  def print_tool_call(name, args, context \\ :main) do
    prefix = get_prefix(context)
    color = get_tool_call_color(context)

    IO.write(
      colorize(prefix, color) <>
        colorize("🛠️  • f: ", &Colors.bright_yellow/0) <>
        colorize("#{name}", &Colors.bright_cyan/0) <>
        colorize(" • ", &Colors.bright_yellow/0)
    )

    format_tool_args(name, args, context)
  end

  @doc """
  Print a tool call that was rejected by runtime policy.
  """
  def print_blocked_tool_call(name, args, reason, context \\ :main) do
    prefix = get_prefix(context)
    path = Map.get(args, "filePath") || Map.get(args, "path")

    target =
      if path do
        " path: #{path}"
      else
        ""
      end

    IO.puts(
      "\n" <>
        colorize(prefix, &Colors.bright_yellow/0) <>
        colorize("⛔ blocked tool: ", &Colors.bright_red/0) <>
        colorize("#{name}", &Colors.bright_cyan/0) <>
        colorize(target, &Colors.dim/0) <>
        colorize(" — #{reason}", &Colors.dim/0)
    )
  end

  defp format_tool_args("eeva", args, _context) do
    code =
      args
      |> Map.get("code", "")
      |> String.trim()
      |> String.split(~r/\R/, parts: 2)
      |> List.first()
      |> to_string()

    IO.puts(
      colorize("elixir: ", &Colors.dim/0) <>
        colorize(String.slice(code, 0, 120), &Colors.bright_cyan/0)
    )
  end

  defp format_tool_args(_name, args, _context) do
    IO.puts(colorize("a: ", &Colors.bright_yellow/0) <> inspect(args, pretty: true))
  end

  @doc "
  Print a tool response.
    "
  def print_tool_response(name, content) do
    box(content, "📜 Tool Response: #{name}", &Colors.bright_cyan/0)
  end

  @doc "
  Print an error message.
    "
  def print_error(message) do
    IO.puts("\n" <> colorize("[Error] ", &Colors.bright_red/0) <> message)
  end

  @doc "
  Print a rate limit error.
    "
  def print_rate_limit_error do
    print_error(Beamcore.Agent.Chat.RateLimit.message(nil))
  end

  def print_rate_limit_error(error) do
    print_error(Beamcore.Agent.Chat.RateLimit.message(error))
  end

  @doc "
  Print an API timeout error.
    "
  def print_timeout_error do
    print_error("API request timed out. Retrying with longer timeout...")
  end

  @doc "
  Print a generic API error.
    "
  def print_api_error(error) do
    error_msg =
      if error.message do
        msg = "#{error.message}"
        if error.body, do: msg <> " | Body: #{inspect(error.body)}", else: msg
      else
        "API error (HTTP #{error.status_code || "unknown"})"
      end

    print_error(error_msg)
  end

  @doc "
  Print a warning message.
    "
  def print_warning(message) do
    IO.puts("\n" <> colorize("[Warning] ", &Colors.bright_yellow/0) <> message)
  end

  @doc "
  Print an informational message.
    "
  def print_info(message) do
    IO.puts("\n" <> colorize("[Info] ", &Colors.bright_cyan/0) <> message)
  end

  @doc "
  Print a raw response (for debugging).
    "
  def print_raw_response(response, label \\ "Raw Response") do
    if System.get_env("DEBUG") == "true" do
      box(inspect(response, pretty: true), label, &Colors.dim/0)
    end
  end

  defmodule Spinner do
    @moduledoc "Spinner animation and utilities for long-running tasks."

    @frames [
      "⠋",
      "⠙",
      "⠹",
      "⠸",
      "⠼",
      "⠴",
      "⠦",
      "⠧",
      "⠇",
      "⠏"
    ]

    @doc "Get the spinner frame at a given index (cycles infinitely)."
    def get_frame(index) do
      Enum.at(@frames, rem(index, length(@frames)))
    end

    @doc "Start a spinner with a message. Returns a PID for control."
    def start(message \\ "Processing...") do
      pid = spawn(fn -> loop(0, message) end)
      pid
    end

    @doc "Stop a spinner by its PID."
    def stop(pid) do
      send(pid, :stop)
    end

    defp loop(index, message) do
      frame = get_frame(index)

      IO.write(
        "\r" <> Beamcore.Agent.Core.Pretty.colorize("#{frame} ", &Colors.bright_cyan/0) <> message
      )

      receive do
        :stop ->
          IO.write("\r" <> String.duplicate(" ", String.length(message) + 2) <> "\r")
      after
        100 ->
          loop((index + 1) |> rem(length(@frames)), message)
      end
    end
  end

  # Context-based helpers
  defp get_prefix({:subagent, name}), do: "[#{name}] "
  defp get_prefix(:subagent), do: "[Subagent] "
  defp get_prefix(_), do: ""

  defp get_thinking_color({:subagent, _}), do: &Colors.bright_yellow/0
  defp get_thinking_color(:subagent), do: &Colors.bright_yellow/0
  defp get_thinking_color(_), do: &Colors.bright_magenta/0

  defp get_assistant_color({:subagent, _}), do: &Colors.bright_yellow/0
  defp get_assistant_color(:subagent), do: &Colors.bright_yellow/0
  defp get_assistant_color(_), do: &Colors.bright_blue/0

  defp get_tool_call_color({:subagent, _}), do: &Colors.bright_yellow/0
  defp get_tool_call_color(:subagent), do: &Colors.bright_yellow/0
  defp get_tool_call_color(_), do: &Colors.bright_yellow/0
end
