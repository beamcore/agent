defmodule Beamcore.TUI.Components.Providers.Form do
  @moduledoc false

  alias ExRatatui.Text.{Line, Span}

  @field_width 54
  @default_visible_rows 12
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

  defstruct field: :name,
            name: "",
            key: "",
            url: "",
            model: "",
            auth_strategy: "bearer",
            token_url: "",
            client_id: "",
            client_secret: "",
            scope: "",
            credentials_file: "",
            token_request_id_header: "",
            cacertfile: "",
            ssl_verify: "auto",
            mode: :bearer,
            error: nil,
            fields: nil,
            scroll_offset: 0,
            visible_rows: @default_visible_rows

  def new(opts \\ []) do
    fields = Keyword.get(opts, :fields)

    %__MODULE__{fields: fields}
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  def render(form, muted, accent, input_style, visible_rows \\ nil) do
    form =
      form
      |> auto_detect_mode()
      |> set_visible_rows(visible_rows)
      |> ensure_focus_valid()
      |> ensure_focus_visible()

    mode_label = strategy_label(form.mode)

    mode_style =
      if form.mode in [:oauth2_client_credentials, :google_adc], do: accent, else: muted

    rows =
      form
      |> visible_fields()
      |> Enum.flat_map(fn field ->
        f = field.id
        value = field_value(form, f)
        active? = form.field == f
        cursor = if active?, do: "█", else: ""
        label_s = if active?, do: accent, else: muted
        input_s = if active?, do: accent, else: input_style
        req = if required?(field, form.mode), do: " *", else: ""
        display = truncate_display(value <> cursor, @field_width)
        padded = String.pad_trailing(display, @field_width)

        [
          %Line{
            spans: [
              %Span{content: "  #{field.label}#{req}", style: label_s}
            ]
          },
          %Line{
            spans: [
              %Span{content: "  ┌#{String.duplicate("─", @field_width + 2)}┐", style: muted}
            ]
          },
          %Line{
            spans: [
              %Span{content: "  │ #{padded} │", style: input_s}
            ]
          },
          %Line{
            spans: [
              %Span{content: "  └#{String.duplicate("─", @field_width + 2)}┘", style: muted}
            ]
          }
        ]
      end)

    error_line =
      if form.error do
        [%Line{spans: [%Span{content: "  #{form.error}", style: %{accent | fg: :red}}]}]
      else
        []
      end

    lines =
      [
        %Line{spans: [%Span{content: ""}]},
        %Line{
          spans: [
            %Span{content: "  Add Provider  ", style: accent},
            %Span{content: "[#{mode_label}]", style: mode_style},
            %Span{
              content: "  (auth: bearer | oauth2_client_credentials | google_adc)",
              style: muted
            }
          ]
        },
        %Line{spans: [%Span{content: "  #{String.duplicate("─", 40)}", style: muted}]}
      ] ++
        rows ++
        error_line ++
        [
          %Line{spans: [%Span{content: ""}]},
          %Line{
            spans: [
              %Span{content: "  tab", style: accent},
              %Span{content: " next  ", style: muted},
              %Span{content: "enter", style: accent},
              %Span{content: " save  ", style: muted},
              %Span{content: "esc", style: accent},
              %Span{content: " cancel", style: muted}
            ]
          }
        ]

    if is_integer(visible_rows) do
      scroll_lines(lines, form.scroll_offset, form.visible_rows)
    else
      lines
    end
  end

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

  def handle_key("tab", mods, form) do
    if shift?(mods), do: previous_field(form, wrap?: true), else: next_field(form, wrap?: true)
  end

  def handle_key("back_tab", _mods, form), do: previous_field(form, wrap?: true)

  def handle_key("down", _mods, form), do: next_field(form, wrap?: false)

  def handle_key("up", _mods, form), do: previous_field(form, wrap?: false)

  def handle_key(key, _mods, %{field: :auth_strategy} = form)
      when key in ["left", "right", " "] do
    direction = if key == "left", do: -1, else: 1

    form
    |> cycle_auth_strategy(direction)
    |> ensure_focus_visible()
  end

  def handle_key("enter", _mods, form) do
    form = auto_detect_mode(form)

    cond do
      form.name == "" ->
        focus_field(%{form | error: "name required"}, :name)

      form.mode in [:bearer, :api_key] and form.key == "" ->
        focus_field(%{form | error: "key required"}, :key)

      form.mode == :oauth2_client_credentials and form.token_url == "" ->
        focus_field(%{form | error: "token url required for OAuth2"}, :token_url)

      form.mode == :oauth2_client_credentials and form.key == "" and form.client_id == "" ->
        focus_field(%{form | error: "client id required for OAuth2"}, :client_id)

      form.mode == :oauth2_client_credentials and form.key == "" and form.client_secret == "" ->
        focus_field(%{form | error: "client secret required for OAuth2"}, :client_secret)

      true ->
        auth = auth_config(form)

        config =
          %{
            "api_key" => non_empty(form.key),
            "base_url" => non_empty(form.url),
            "default_model" => non_empty(form.model),
            "auth" => auth,
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
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> Map.new()

        {:save, form.name, config, form}
    end
  end

  def handle_key("esc", _mods, form), do: {:cancel, form}

  def handle_key("delete", _mods, form), do: handle_backspace(form)

  def handle_key(key, _mods, form) do
    char = if String.length(key) == 1, do: key, else: ""
    form = ensure_focus_valid(form)
    field = field_atom(form.field)

    form
    |> update_field_text(field, char)
    |> auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  def handle_backspace(form) do
    form = ensure_focus_valid(form)
    field = field_atom(form.field)
    current = Map.get(form, field)
    new_val = if String.length(current) > 0, do: String.slice(current, 0..-2//1), else: current

    %{Map.put(form, field, new_val) | error: nil}
    |> auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  def insert_text(form, text) do
    form = ensure_focus_valid(form)
    field = field_atom(form.field)
    clean = String.replace(text, "\n", " ")

    form
    |> update_field_text(field, clean)
    |> auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  # -- Private -----------------------------------------------------------------

  defp update_field_text(form, :auth_strategy, text) do
    current = String.trim(form.auth_strategy)

    value =
      cond do
        text == "" -> current
        complete_strategy?(current) -> text
        true -> current <> text
      end

    %{form | auth_strategy: value, error: nil}
  end

  defp update_field_text(form, field, text) do
    %{Map.update!(form, field, &(&1 <> text)) | error: nil}
  end

  defp cycle_auth_strategy(form, direction) do
    strategies = [:bearer, :api_key, :oauth2_client_credentials, :google_adc, :none]
    current = normalize_strategy(String.trim(form.auth_strategy))
    idx = Enum.find_index(strategies, &(&1 == current)) || 0
    next = Enum.at(strategies, rem(idx + direction + length(strategies), length(strategies)))

    %{form | auth_strategy: strategy_input(next), mode: next, error: nil}
  end

  defp next_field(form, opts) do
    form = auto_detect_mode(form)
    ids = focusable_field_ids(form)
    idx = Enum.find_index(ids, &(&1 == form.field)) || 0
    next = next_id(ids, idx, Keyword.fetch!(opts, :wrap?))

    form =
      if form.field == :name and next == :key do
        auto = auto_fill(form.name)
        %{form | url: form.url || auto.url, model: form.model || auto.model}
      else
        form
      end

    focus_field(%{form | error: nil}, next)
  end

  defp previous_field(form, opts) do
    form = auto_detect_mode(form)
    ids = focusable_field_ids(form)
    idx = Enum.find_index(ids, &(&1 == form.field)) || 0
    previous = previous_id(ids, idx, Keyword.fetch!(opts, :wrap?))

    focus_field(%{form | error: nil}, previous)
  end

  defp next_id([], _idx, _wrap?), do: nil
  defp next_id(ids, idx, true), do: Enum.at(ids, rem(idx + 1, length(ids)))
  defp next_id(ids, idx, false), do: Enum.at(ids, min(idx + 1, length(ids) - 1))

  defp previous_id([], _idx, _wrap?), do: nil
  defp previous_id(ids, idx, true), do: Enum.at(ids, rem(idx - 1 + length(ids), length(ids)))
  defp previous_id(ids, idx, false), do: Enum.at(ids, max(idx - 1, 0))

  defp required?(%{required?: true}, _mode), do: true
  defp required?(%{required_when: mode}, mode), do: true
  defp required?(_field, _mode), do: false

  defp field_value(form, :name), do: form.name
  defp field_value(form, :key), do: mask(form.key)
  defp field_value(form, :url), do: form.url
  defp field_value(form, :model), do: form.model
  defp field_value(form, :auth_strategy), do: form.auth_strategy
  defp field_value(form, :token_url), do: form.token_url
  defp field_value(form, :client_id), do: form.client_id
  defp field_value(form, :client_secret), do: mask(form.client_secret)
  defp field_value(form, :scope), do: form.scope
  defp field_value(form, :credentials_file), do: form.credentials_file
  defp field_value(form, :token_request_id_header), do: form.token_request_id_header
  defp field_value(form, :cacertfile), do: form.cacertfile
  defp field_value(form, :ssl_verify), do: form.ssl_verify

  defp field_atom(:name), do: :name
  defp field_atom(:key), do: :key
  defp field_atom(:url), do: :url
  defp field_atom(:model), do: :model
  defp field_atom(:auth_strategy), do: :auth_strategy
  defp field_atom(:token_url), do: :token_url
  defp field_atom(:client_id), do: :client_id
  defp field_atom(:client_secret), do: :client_secret
  defp field_atom(:scope), do: :scope
  defp field_atom(:credentials_file), do: :credentials_file
  defp field_atom(:token_request_id_header), do: :token_request_id_header
  defp field_atom(:cacertfile), do: :cacertfile
  defp field_atom(:ssl_verify), do: :ssl_verify

  defp fields(%{fields: nil}), do: @fields
  defp fields(%{fields: fields}) when is_list(fields), do: Enum.map(fields, &normalize_field/1)

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

  defp focusable_field_ids(form), do: form |> focusable_fields() |> Enum.map(& &1.id)

  defp focus_field(form, nil), do: form

  defp focus_field(form, field) do
    %{form | field: field}
    |> ensure_focus_visible()
  end

  defp ensure_focus_valid(form) do
    ids = focusable_field_ids(form)

    if form.field in ids do
      form
    else
      focus_field(form, List.first(ids))
    end
  end

  defp set_visible_rows(form, rows) when is_integer(rows) and rows > 0,
    do: %{form | visible_rows: rows}

  defp set_visible_rows(form, _rows), do: form

  defp ensure_focus_visible(%{field: nil} = form), do: form

  defp ensure_focus_visible(form) do
    case field_line_range(form, form.field) do
      nil ->
        form

      {first, last} ->
        max_offset = max(total_line_count(form) - form.visible_rows, 0)

        offset =
          cond do
            first < form.scroll_offset -> first
            last >= form.scroll_offset + form.visible_rows -> last - form.visible_rows + 1
            true -> form.scroll_offset
          end
          |> max(0)
          |> min(max_offset)

        %{form | scroll_offset: offset}
    end
  end

  defp field_line_range(form, field_id) do
    form
    |> visible_fields()
    |> Enum.find_index(&(&1.id == field_id))
    |> case do
      nil -> nil
      idx -> {3 + idx * 4, 3 + idx * 4 + 3}
    end
  end

  defp total_line_count(form) do
    field_count = length(visible_fields(form))
    error_count = if form.error, do: 1, else: 0
    3 + field_count * 4 + error_count + 2
  end

  defp scroll_lines(lines, offset, visible_rows) do
    if length(lines) > visible_rows do
      Enum.slice(lines, offset, visible_rows)
    else
      lines
    end
  end

  defp auto_detect_mode(form) do
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

  defp normalize_strategy(""), do: :bearer
  defp normalize_strategy("openai"), do: :bearer
  defp normalize_strategy("bearer"), do: :bearer
  defp normalize_strategy("api_key"), do: :api_key
  defp normalize_strategy("none"), do: :none
  defp normalize_strategy("oauth2"), do: :oauth2_client_credentials
  defp normalize_strategy("client_credentials"), do: :oauth2_client_credentials
  defp normalize_strategy("oauth2_client_credentials"), do: :oauth2_client_credentials
  defp normalize_strategy("google_adc"), do: :google_adc
  defp normalize_strategy(_value), do: :bearer

  defp complete_strategy?(value),
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

  defp strategy_input(:oauth2_client_credentials), do: "oauth2_client_credentials"
  defp strategy_input(strategy), do: Atom.to_string(strategy)

  defp strategy_label(:oauth2_client_credentials), do: "OAuth2 client credentials"
  defp strategy_label(:google_adc), do: "Google ADC"
  defp strategy_label(:api_key), do: "API key"
  defp strategy_label(:none), do: "None"
  defp strategy_label(_strategy), do: "Bearer"

  defp auth_config(%{mode: :bearer}), do: nil
  defp auth_config(%{mode: :oauth2_client_credentials} = form), do: oauth_auth_config(form)
  defp auth_config(%{mode: :google_adc} = form), do: google_adc_auth_config(form)
  defp auth_config(%{mode: mode}), do: Atom.to_string(mode)

  defp oauth_auth_config(form) do
    %{
      "strategy" => "oauth2_client_credentials",
      "scope" => non_empty(form.scope)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp google_adc_auth_config(form) do
    %{
      "strategy" => "google_adc",
      "scope" => non_empty(form.scope),
      "credentials_file" => non_empty(form.credentials_file)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp ssl_verify_value(value) when value in ["false", "FALSE", "0", "no", "NO"], do: false
  defp ssl_verify_value(value) when value in ["true", "TRUE", "1", "yes", "YES"], do: true
  defp ssl_verify_value(value) when value in ["auto", "AUTO", ""], do: "auto"
  defp ssl_verify_value(_value), do: nil

  defp non_empty(value) when is_binary(value), do: if(value == "", do: nil, else: value)
  defp non_empty(_value), do: nil

  defp auto_fill(name) do
    case Beamcore.Provider.Registry.get(name) do
      nil -> %{url: "", model: ""}
      info -> %{url: info.base_url || "", model: info.default_model || ""}
    end
  rescue
    _ -> %{url: "", model: ""}
  end

  defp mask(value) do
    case String.length(value) do
      0 -> ""
      n when n <= 4 -> value
      _ -> String.slice(value, 0, 3) <> String.duplicate("•", String.length(value) - 3)
    end
  end

  defp truncate_display(text, max_len) do
    if String.length(text) <= max_len, do: text, else: String.slice(text, 0, max_len - 1) <> "…"
  end

  defp shift?(nil), do: false
  defp shift?(mods), do: "shift" in mods
end
