defmodule Beamcore.Provider.ModelContext do
  @moduledoc """
  Maps known model names to their context window sizes.

  This provides a canonical reference for how many tokens each model can handle
  in its context window, used by the status bar and capability resolution.
  """

  @doc """
  Returns the context window size (in tokens) for a given model, or `nil` if unknown.

  ## Examples

      iex> Beamcore.Provider.ModelContext.context_size("gpt-4o")
      128_000

      iex> Beamcore.Provider.ModelContext.context_size("unknown-model")
      nil
  """
  @spec context_size(binary()) :: pos_integer() | nil
  def context_size(model) when is_binary(model) do
    @model_contexts[model]
  end

  @doc """
  Formats a context size as a human-readable string like "128k" or "8k".

  Returns `nil` if the context size is unknown.
  """
  @spec format(pos_integer() | nil) :: binary() | nil
  def format(nil), do: nil

  def format(size) when is_integer(size) and size > 0 do
    cond do
      size >= 1_000_000 ->
        Float.round(size / 1_000_000, 1)
        |> then(fn n -> if n == trunc(n), do: trunc(n), else: n end)
        |> Kernel.<>("M")

      size >= 1_000 ->
        Float.round(size / 1_000, 1)
        |> then(fn n -> if n == trunc(n), do: trunc(n), else: n end)
        |> Kernel.<>("k")

      true ->
        Integer.to_string(size)
    end
  end

  @doc """
  Formats a model name with its context size, e.g. `"gpt-4o:128k"`.

  Returns just the model name if context size is unknown.
  """
  @spec model_label(binary()) :: binary()
  def model_label(model) when is_binary(model) do
    case context_size(model) do
      nil -> model
      size -> "#{model}:#{format(size)}"
    end
  end

  # Known model context window sizes (in tokens)
  # Sources: official documentation, API responses, and provider specs
  @model_contexts %{
    # --- OpenAI ---
    "gpt-4o" => 128_000,
    "gpt-4o-2024-08-06" => 128_000,
    "gpt-4o-2024-05-13" => 128_000,
    "gpt-4o-mini" => 128_000,
    "gpt-4o-mini-2024-07-18" => 128_000,
    "gpt-4-turbo" => 128_000,
    "gpt-4-turbo-2024-04-09" => 128_000,
    "gpt-4-turbo-preview" => 128_000,
    "gpt-4-0125-preview" => 128_000,
    "gpt-4-1106-preview" => 128_000,
    "gpt-4" => 8_192,
    "gpt-4-0613" => 8_192,
    "gpt-4-32k" => 32_768,
    "gpt-4-32k-0613" => 32_768,
    "gpt-3.5-turbo" => 16_385,
    "gpt-3.5-turbo-0125" => 16_385,
    "gpt-3.5-turbo-1106" => 16_385,
    "gpt-3.5-turbo-16k" => 16_385,
    "o1-preview" => 128_000,
    "o1-preview-2024-09-12" => 128_000,
    "o1-mini" => 128_000,
    "o1-mini-2024-09-12" => 128_000,
    "o1" => 200_000,
    "o3-mini" => 200_000,
    "gpt-4.5-preview" => 128_000,

    # --- Mistral ---
    "mistral-large-2411" => 128_000,
    "mistral-large-2407" => 128_000,
    "mistral-medium-3-5" => 32_000,
    "mistral-medium-2312" => 32_000,
    "mistral-small-3-5" => 32_000,
    "mistral-small-2312" => 32_000,
    "mistral-7b" => 32_000,
    "mistral-8x7b" => 32_000,
    "codestral-latest" => 256_000,
    "codestral-2501" => 256_000,
    "pixtral-12b-2409" => 128_000,
    "ministral-8b-2410" => 128_000,
    "ministral-3b-2410" => 128_000,

    # --- DeepSeek ---
    "deepseek-chat" => 64_000,
    "deepseek-coder" => 64_000,
    "deepseek-reasoner" => 64_000,
    "deepseek-v3" => 64_000,
    "deepseek-r1" => 64_000,

    # --- Anthropic (for reference, though not yet directly supported) ---
    "claude-3-opus-20240229" => 200_000,
    "claude-3-sonnet-20240229" => 200_000,
    "claude-3-haiku-20240307" => 200_000,
    "claude-3-5-sonnet-20240620" => 200_000,
    "claude-3-5-haiku-20241022" => 200_000,
    "claude-opus-4-20250514" => 200_000,

    # --- Google / Gemini ---
    "gemini-1.5-pro" => 2_000_000,
    "gemini-1.5-flash" => 1_000_000,
    "gemini-2.0-flash" => 1_000_000,
    "gemini-2.5-pro" => 1_000_000,
    "gemma2:latest" => 8_192,
    "gemma4:latest" => 8_192,
    "gemma:latest" => 8_192,

    # --- Common Ollama / local models ---
    "llama3.1:latest" => 128_000,
    "llama3.1:8b" => 128_000,
    "llama3.1:70b" => 128_000,
    "llama3.1:405b" => 128_000,
    "llama3:latest" => 8_192,
    "llama2:latest" => 4_096,
    "llama3.2:latest" => 128_000,
    "llama3.2:1b" => 128_000,
    "llama3.2:3b" => 128_000,
    "llama3.2-vision:latest" => 128_000,
    "codellama:latest" => 16_384,
    "mistral:latest" => 32_000,
    "mixtral:latest" => 32_000,
    "phi3:latest" => 128_000,
    "phi3:mini" => 128_000,
    "phi3:medium" => 128_000,
    "qwen2.5:latest" => 32_000,
    "qwen2.5:7b" => 32_000,
    "qwen2.5:72b" => 32_000,
    "deepseek-coder-v2:latest" => 128_000,
    "deepseek-r1:latest" => 64_000
  }
end
