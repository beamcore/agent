defmodule Beamcore.Provider.Error do
  @moduledoc """
  Typed provider error shared by provider adapters and routing code.
  """

  defexception [:provider, :kind, :message, :status, :retry_after_ms, :details]

  @type kind ::
          :missing_config
          | :invalid_config
          | :unavailable
          | :unsupported_capability
          | :rate_limit
          | :timeout
          | :bad_request
          | :provider_error

  @type t :: %__MODULE__{
          provider: atom() | nil,
          kind: kind(),
          message: binary(),
          status: pos_integer() | nil,
          retry_after_ms: non_neg_integer() | nil,
          details: map() | nil
        }

  @impl true
  def exception(opts) do
    kind = Keyword.fetch!(opts, :kind)
    provider = Keyword.get(opts, :provider)

    message =
      Keyword.get(opts, :message) ||
        default_message(provider, kind)

    %__MODULE__{
      provider: provider,
      kind: kind,
      message: message,
      status: Keyword.get(opts, :status),
      retry_after_ms: Keyword.get(opts, :retry_after_ms),
      details: Keyword.get(opts, :details)
    }
  end

  defp default_message(nil, kind), do: "Provider error: #{kind}"
  defp default_message(provider, kind), do: "Provider #{provider} error: #{kind}"
end
