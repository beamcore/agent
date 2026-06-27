defmodule Beamcore.TUI.Components.Providers.Form.Auth do
  @moduledoc false

  @strategies [:bearer, :api_key, :oauth2_client_credentials, :google_adc, :none]

  def cycle(form, direction) do
    current = normalize_strategy(String.trim(form.auth_strategy))
    idx = Enum.find_index(@strategies, &(&1 == current)) || 0
    next = Enum.at(@strategies, rem(idx + direction + length(@strategies), length(@strategies)))

    %{form | auth_strategy: strategy_input(next), mode: next, error: nil}
  end

  def auto_detect_mode(form) do
    raw_strategy = String.trim(form.auth_strategy)
    strategy = normalize_strategy(raw_strategy)

    strategy =
      if form.token_url != "" and strategy == :bearer do
        :oauth2_client_credentials
      else
        strategy
      end

    auth_strategy =
      cond do
        form.token_url != "" and raw_strategy in ["", "bearer", "openai"] ->
          strategy_input(strategy)

        form.field == :auth_strategy and not complete_strategy?(raw_strategy) ->
          form.auth_strategy

        true ->
          strategy_input(strategy)
      end

    %{form | auth_strategy: auth_strategy, mode: strategy}
  end

  def build_config(form) do
    %{
      "api_key" => non_empty(form.key),
      "base_url" => non_empty(form.url),
      "default_model" => non_empty(form.model),
      "auth" => auth_config(form),
      "token_url" => non_empty(form.token_url),
      "client_id" => non_empty(form.client_id),
      "client_secret" => non_empty(form.client_secret),
      "scope" => non_empty(form.scope),
      "credentials_file" => non_empty(form.credentials_file),
      "token_request_id_header" => non_empty(form.token_request_id_header),
      "cacertfile" => non_empty(form.cacertfile),
      "ssl_verify" =>
        if(form.mode == :oauth2_client_credentials, do: ssl_verify_value(form.ssl_verify))
    }
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Map.new()
  end

  def normalize_strategy(""), do: :bearer
  def normalize_strategy("openai"), do: :bearer
  def normalize_strategy("bearer"), do: :bearer
  def normalize_strategy("api_key"), do: :api_key
  def normalize_strategy("none"), do: :none
  def normalize_strategy("oauth2"), do: :oauth2_client_credentials
  def normalize_strategy("client_credentials"), do: :oauth2_client_credentials
  def normalize_strategy("oauth2_client_credentials"), do: :oauth2_client_credentials
  def normalize_strategy("google_adc"), do: :google_adc
  def normalize_strategy(_value), do: :bearer

  def complete_strategy?(value),
    do:
      value in [
        "",
        "openai",
        "bearer",
        "api_key",
        "none",
        "oauth2",
        "client_credentials",
        "oauth2_client_credentials",
        "google_adc"
      ]

  def strategy_input(:oauth2_client_credentials), do: "oauth2_client_credentials"
  def strategy_input(strategy), do: Atom.to_string(strategy)

  def strategy_label(:oauth2_client_credentials), do: "OAuth2 client credentials"
  def strategy_label(:google_adc), do: "Google ADC"
  def strategy_label(:api_key), do: "API key"
  def strategy_label(:none), do: "None"
  def strategy_label(_strategy), do: "Bearer"

  defp auth_config(%{mode: :bearer}), do: nil
  defp auth_config(%{mode: :oauth2_client_credentials} = form), do: oauth_auth_config(form)
  defp auth_config(%{mode: :google_adc} = form), do: google_adc_auth_config(form)
  defp auth_config(%{mode: mode}), do: Atom.to_string(mode)

  defp oauth_auth_config(form) do
    %{
      "strategy" => "oauth2_client_credentials",
      "scope" => non_empty(form.scope)
    }
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp google_adc_auth_config(form) do
    %{
      "strategy" => "google_adc",
      "scope" => non_empty(form.scope),
      "credentials_file" => non_empty(form.credentials_file)
    }
    |> Enum.reject(fn {_, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp ssl_verify_value(value) when value in ["false", "FALSE", "0", "no", "NO"], do: false
  defp ssl_verify_value(value) when value in ["true", "TRUE", "1", "yes", "YES"], do: true
  defp ssl_verify_value(value) when value in ["auto", "AUTO", ""], do: "auto"
  defp ssl_verify_value(_value), do: nil

  defp non_empty(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp non_empty(_value), do: nil
end
