defmodule Beamcore.Agent.Tools.Grep do
  @moduledoc """
  Allows for content search
  """

  @description """
  Perform fast regular expression searches in file contents across any codebase size.
  Supports filtering files using glob patterns with the optional include parameter.
  Returns matching lines with their file paths and line numbers sorted by modification time.
  """

  def name, do: "grep"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            pattern: %{
              type: "string",
              description: "The regex pattern to search for in file contents"
            },
            path: %{
              type: "string",
              description:
                "The directory to search in. Defaults to the current working directory."
            },
            include: %{
              type: "string",
              description: "File pattern to include in the search (e.g. \"*.js\", \"*.{ts,tsx}\")"
            },
            all: %{
              type: "boolean",
              description: "If true, search in hidden and ignored files. Defaults to false."
            },
            offset: %{
              type: "integer",
              description: "The match number to start reading from (1-indexed)"
            },
            limit: %{
              type: "integer",
              description: "The maximum number of matches to return (defaults to 50)"
            }
          },
          required: ["pattern"]
        }
      }
    }
  end

  def execute(params) do
    pattern = Map.fetch!(params, "pattern")
    path = Map.get(params, "path", ".")
    include = Map.get(params, "include")
    show_all = Map.get(params, "all", false)
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit", 50)

    common_args = [
      "--line-number",
      "--with-filename",
      "--no-heading",
      "--color=never",
      "--sortr=modified",
      "-e",
      pattern
    ]

    common_args =
      if show_all do
        ["--no-ignore", "--hidden" | common_args]
      else
        common_args
      end

    if include && !show_all do
      execute_git_filtered_grep(pattern, path, include, common_args, offset, limit)
    else
      args =
        if include do
          ["-g", include | common_args]
        else
          common_args
        end

      case System.cmd("rg", args ++ [path], stderr_to_stdout: true) do
        {output, 0} ->
          paginate_output(output, offset, limit)

        {output, 1} ->
          if String.trim(output) == "" do
            "No matches found."
          else
            paginate_output(output, offset, limit)
          end

        {output, _} ->
          "Error running grep: #{truncate(output)}"
      end
    end
  end

  defp execute_git_filtered_grep(_pattern, path, include, args, offset, limit) do
    # git ls-files respects .gitignore and matches the pattern correctly without overriding
    git_args = ["ls-files", "--cached", "--others", "--exclude-standard", include]

    case System.cmd("git", git_args, cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        files = String.split(output, "\n", trim: true)

        if files == [] do
          "No matches found."
        else
          # Run rg on the filtered file list
          case System.cmd("rg", args ++ files, cd: path, stderr_to_stdout: true) do
            {output, 0} ->
              paginate_output(output, offset, limit)

            {output, 1} ->
              if String.trim(output) == "" do
                "No matches found."
              else
                paginate_output(output, offset, limit)
              end

            {output, _} ->
              "Error running grep (rg): #{truncate(output)}"
          end
        end

      {_output, _} ->
        # Fallback to standard rg if git fails
        case System.cmd("rg", ["-g", include | args] ++ [path], stderr_to_stdout: true) do
          {output, 0} ->
            paginate_output(output, offset, limit)

          {output, 1} ->
            if String.trim(output) == "" do
              "No matches found."
            else
              paginate_output(output, offset, limit)
            end

          {output, _} ->
            "Error running grep (fallback): #{truncate(output)}"
        end
    end
  end

  defp paginate_output(output, offset, limit) do
    lines = String.split(output, "\n", trim: true)
    total_lines = length(lines)
    start_idx = max(0, offset - 1)
    sliced_lines = Enum.slice(lines, start_idx, limit)
    shown_count = length(sliced_lines)
    left_count = total_lines - (start_idx + shown_count)

    result = Enum.join(sliced_lines, "\n")

    cond do
      total_lines == 0 ->
        "No matches found."

      left_count > 0 ->
        last = offset + shown_count - 1
        next = last + 1

        result <>
          "\n\n(Showing matches #{offset}-#{last}. #{left_count} matches left. Use offset=#{next} to continue.)"

      true ->
        result <> "\n\n(#{total_lines} matches found. End of matches.)"
    end
  end

  defp truncate(output, max \\ 10_000) do
    if byte_size(output) > max,
      do: String.slice(output, 0, max) <> "\n... (truncated)",
      else: output
  end
end
