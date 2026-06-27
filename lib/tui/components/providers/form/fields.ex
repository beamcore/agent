defmodule Beamcore.TUI.Components.Providers.Form.Fields do
  @moduledoc false

  @fields [
    %{id: :name, label: "name", required?: true},
    %{id: :key, label: "api key"},
    %{id: :url, label: "base url"},
    %{id: :model, label: "model"},
    %{id: :auth_strategy, label: "auth strategy"},
    %{id: :token_url, label: "token url"},
    %{id: :client_id, label: "client id", strategies: [:oauth2_client_credentials]},
    %{id: :client_secret, label: "client secret", strategies: [:oauth2_client_credentials]},
    %{id: :scope, label: "scope", strategies: [:oauth2_client_credentials, :google_adc]},
    %{id: :credentials_file, label: "credentials file", strategies: [:google_adc]},
    %{
      id: :token_request_id_header,
      label: "request id header",
      strategies: [:oauth2_client_credentials]
    },
    %{id: :cacertfile, label: "ca cert file", strategies: [:oauth2_client_credentials]},
    %{id: :ssl_verify, label: "ssl verify", strategies: [:oauth2_client_credentials]}
  ]

  def fields(%{fields: nil}), do: @fields
  def fields(%{fields: fields}) when is_list(fields), do: Enum.map(fields, &normalize_field/1)

  def visible_fields(form) do
    form
    |> fields()
    |> Enum.reject(&field_hidden?(&1, form))
  end

  def focusable_fields(form) do
    form
    |> visible_fields()
    |> Enum.reject(&field_disabled?/1)
    |> Enum.filter(&field_editable?/1)
  end

  def focusable_field_ids(form), do: form |> focusable_fields() |> Enum.map(& &1.id)

  def required?(%{required?: true}, _mode), do: true
  def required?(%{required_when: mode}, mode), do: true
  def required?(_field, _mode), do: false

  def field_atom(field)
      when field in [
             :name,
             :key,
             :url,
             :model,
             :auth_strategy,
             :token_url,
             :client_id,
             :client_secret,
             :scope,
             :credentials_file,
             :token_request_id_header,
             :cacertfile,
             :ssl_verify
           ],
      do: field

  defp normalize_field(field) when is_atom(field), do: %{id: field, label: to_string(field)}

  defp normalize_field(field) when is_map(field) do
    id = Map.get(field, :id) || Map.fetch!(field, "id")

    field =
      field
      |> Enum.map(fn {key, value} -> {normalize_field_key(key), value} end)
      |> Map.new()

    Map.put_new(field, :label, to_string(id))
  end

  defp normalize_field_key("id"), do: :id
  defp normalize_field_key("label"), do: :label
  defp normalize_field_key("required?"), do: :required?
  defp normalize_field_key("required_when"), do: :required_when
  defp normalize_field_key("hidden?"), do: :hidden?
  defp normalize_field_key("disabled?"), do: :disabled?
  defp normalize_field_key("editable?"), do: :editable?
  defp normalize_field_key("oauth?"), do: :oauth?
  defp normalize_field_key("strategies"), do: :strategies
  defp normalize_field_key(key), do: key

  defp field_hidden?(field, form) do
    Map.get(field, :hidden?, false) or strategy_hidden?(field, form)
  end

  defp strategy_hidden?(field, form) do
    strategies = Map.get(field, :strategies)
    is_list(strategies) and form.mode not in strategies
  end

  defp field_disabled?(field), do: Map.get(field, :disabled?, false)
  defp field_editable?(field), do: Map.get(field, :editable?, true)
end
