defmodule Beamcore.Retry do
  @moduledoc """
  Retry mechanism with exponential backoff and budget for API calls.
  """

  @default_max_retries 50
  @default_initial_backoff 3000
  @default_max_backoff 60000
  @default_backoff_multiplier 2
  @default_retryable_errors [
    :rate_limit,
    :api_timeout_error,
    :api_connection_error,
    :internal_server_error,
    :bad_request
  ]

  @doc """
  Configuration struct for retry behavior.
  """
  defmodule Config do
    defstruct [
      :max_retries,
      :initial_backoff,
      :max_backoff,
      :backoff_multiplier,
      :retryable_errors,
      :sleep_fun
    ]

    @type t :: %__MODULE__{}

    def default do
      %__MODULE__{
        max_retries: Beamcore.Retry.default_max_retries(),
        initial_backoff: Beamcore.Retry.default_initial_backoff(),
        max_backoff: Beamcore.Retry.default_max_backoff(),
        backoff_multiplier: Beamcore.Retry.default_backoff_multiplier(),
        retryable_errors: Beamcore.Retry.default_retryable_errors(),
        sleep_fun: &Process.sleep/1
      }
    end
  end

  def default_max_retries, do: @default_max_retries
  def default_initial_backoff, do: @default_initial_backoff
  def default_max_backoff, do: @default_max_backoff
  def default_backoff_multiplier, do: @default_backoff_multiplier
  def default_retryable_errors, do: @default_retryable_errors

  @doc """
  Executes a function with retry logic and exponential backoff.

  Returns {:ok, result} on success or {:error, reason} after exhausting retries.
  """
  @spec execute((-> {:ok, any()} | {:error, any()}), Config.t()) :: {:ok, any()} | {:error, any()}
  def execute(func, config \\ Config.default()) do
    execute_with_attempt(func, config, 0, config.initial_backoff)
  end

  defp execute_with_attempt(func, config, attempt, _backoff) when attempt >= config.max_retries do
    IO.write("[r:#{config.max_retries}]")
    func.()
  end

  defp execute_with_attempt(func, config, attempt, backoff) do
    if attempt > 0, do: sleep(config, 1000)

    case func.() do
      {:ok, result} ->
        {:ok, result}

      {:error, %OpenaiEx.Error{} = error} ->
        # Extract error details for debugging non-retryable errors
        error_details =
          if error.message do
            "message: #{error.message}"
          else
            "status_code: #{error.status_code || ~c"unknown"}"
          end

        error_body =
          if error.body do
            " | body: #{inspect(error.body)}"
          else
            ""
          end

        if error.kind in config.retryable_errors do
          # Use longer backoff for timeout errors
          current_backoff = retry_backoff(error, config, backoff)

          sleep(config, current_backoff)
          new_backoff = min(config.max_backoff, current_backoff * config.backoff_multiplier)
          execute_with_attempt(func, config, attempt + 1, new_backoff)
        else
          # Include full error details for non-retryable errors (e.g., bad_request)
          {:error, "API error: #{error.kind} (#{error_details}#{error_body})"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_backoff(%OpenaiEx.Error{kind: :rate_limit} = error, config, backoff) do
    error
    |> Beamcore.Agent.Chat.RateLimit.retry_after_ms()
    |> case do
      wait_ms when is_integer(wait_ms) and wait_ms > 0 -> min(wait_ms, config.max_backoff)
      _ -> backoff
    end
  end

  defp retry_backoff(%OpenaiEx.Error{kind: :api_timeout_error}, config, backoff),
    do: max(backoff * 2, config.initial_backoff * 2)

  defp retry_backoff(_error, _config, backoff), do: backoff

  defp sleep(config, milliseconds) do
    sleep_fun = Map.get(config, :sleep_fun) || (&Process.sleep/1)
    sleep_fun.(milliseconds)
  end
end
