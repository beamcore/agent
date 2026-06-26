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
    %{id: :token_url, label: "token url"},
    %{id: :client_id, label: "client id", oauth?: true},
    %{id: :client_secret, label: "client secret", oauth?: true},
    %{id: :scope, label: "scope", oauth?: true},
    %{id: :token_request_id_header, label: "request id header", oauth?: true},
    %{id: :cacertfile, label: "ca cert file", oauth?: true},
    %{id: :ssl_verify, label: "ssl verify", oauth?: true}
  ]

  defstruct field: :name,
            name: "",
            key: "",
            url: "",
            model: "",
            token_url: "",
            client_id: "",
            client_secret: "",
            scope: "",
            token_request_id_header: "",
            cacertfile: "",
            ssl_verify: "auto",
            mode: :openai,
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

    mode_label = if form.mode == :oauth2, do: "OAuth2", else: "OpenAI"
    mode_style = if form.mode == :oauth2, do: accent, else: muted

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
            %Span{content: "  (fill token url = OAuth2)", style: muted}
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

  def handle_key("enter", _mods, form) do
    form = auto_detect_mode(form)

    cond do
      form.name == "" ->
        focus_field(%{form | error: "name required"}, :name)

      form.mode != :oauth2 and form.key == "" ->
        focus_field(%{form | error: "key required"}, :key)

      form.mode == :oauth2 and form.token_url == "" ->
        focus_field(%{form | error: "token url required for OAuth2"}, :token_url)

      form.mode == :oauth2 and form.key == "" and form.client_id == "" ->
        focus_field(%{form | error: "client id required for OAuth2"}, :client_id)

      form.mode == :oauth2 and form.key == "" and form.client_secret == "" ->
        focus_field(%{form | error: "client secret required for OAuth2"}, :client_secret)

      true ->
        config =
          %{
            "api_key" => non_empty(form.key),
            "base_url" => non_empty(form.url),
            "default_model" => non_empty(form.model),
            "auth" => if(form.mode == :oauth2, do: "oauth2", else: nil),
            "token_url" => non_empty(form.token_url),
            "client_id" => non_empty(form.client_id),
            "client_secret" => non_empty(form.client_secret),
            "scope" => non_empty(form.scope),
            "token_request_id_header" => non_empty(form.token_request_id_header),
            "cacertfile" => non_empty(form.cacertfile),
            "ssl_verify" => ssl_verify_value(form.ssl_verify)
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

    %{Map.update!(form, field, &(&1 <> char)) | error: nil}
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

    %{Map.update!(form, field, &(&1 <> clean)) | error: nil}
    |> auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  # -- Private -----------------------------------------------------------------

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
  defp field_value(form, :token_url), do: form.token_url
  defp field_value(form, :client_id), do: form.client_id
  defp field_value(form, :client_secret), do: mask(form.client_secret)
  defp field_value(form, :scope), do: form.scope
  defp field_value(form, :token_request_id_header), do: form.token_request_id_header
  defp field_value(form, :cacertfile), do: form.cacertfile
  defp field_value(form, :ssl_verify), do: form.ssl_verify

  defp field_atom(:name), do: :name
  defp field_atom(:key), do: :key
  defp field_atom(:url), do: :url
  defp field_atom(:model), do: :model
  defp field_atom(:token_url), do: :token_url
  defp field_atom(:client_id), do: :client_id
  defp field_atom(:client_secret), do: :client_secret
  defp field_atom(:scope), do: :scope
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
  defp normalize_field_key(key), do: key

  defp field_hidden?(field, form) do
    Map.get(field, :hidden?, false) or (Map.get(field, :oauth?, false) and form.mode != :oauth2)
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

  defp auto_detect_mode(form),
    do: if(form.token_url != "", do: %{form | mode: :oauth2}, else: %{form | mode: :openai})

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
