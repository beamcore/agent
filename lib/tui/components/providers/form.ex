defmodule Beamcore.TUI.Components.Providers.Form do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.Form.{Auth, Fields, Renderer}

  @default_visible_rows 12

  defstruct field: :name,
            cursor: 0,
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

  def render(form, muted, accent, input_style, visible_rows \\ nil, width \\ nil) do
    form =
      form
      |> Auth.auto_detect_mode()
      |> set_visible_rows(visible_rows)
      |> ensure_focus_valid()
      |> ensure_focus_visible()

    Renderer.render(form, muted, accent, input_style, visible_rows, width)
  end

  def visible_fields(form), do: Fields.visible_fields(form)

  def focusable_fields(form), do: Fields.focusable_fields(form)

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
    |> Auth.cycle(direction)
    |> move_cursor_to_end()
    |> ensure_focus_visible()
  end

  def handle_key("left", _mods, form), do: move_cursor(form, -1)
  def handle_key("right", _mods, form), do: move_cursor(form, 1)
  def handle_key("home", _mods, form), do: %{ensure_focus_valid(form) | cursor: 0}
  def handle_key("end", _mods, form), do: move_cursor_to_end(form)

  def handle_key("enter", _mods, form) do
    form = Auth.auto_detect_mode(form)

    cond do
      blank?(form.name) ->
        focus_field(%{form | error: "name required"}, :name)

      blank?(form.url) ->
        focus_field(%{form | error: "base url required"}, :url)

      form.mode in [:bearer, :api_key] and blank?(form.key) ->
        focus_field(%{form | error: "key required"}, :key)

      form.mode == :oauth2_client_credentials and blank?(form.token_url) ->
        focus_field(%{form | error: "token url required for OAuth2"}, :token_url)

      form.mode == :oauth2_client_credentials and blank?(form.key) and blank?(form.client_id) ->
        focus_field(%{form | error: "client id required for OAuth2"}, :client_id)

      form.mode == :oauth2_client_credentials and blank?(form.key) and blank?(form.client_secret) ->
        focus_field(%{form | error: "client secret required for OAuth2"}, :client_secret)

      true ->
        {:save, form.name, Auth.build_config(form), form}
    end
  end

  def handle_key("esc", _mods, form), do: {:cancel, form}

  def handle_key("delete", _mods, form), do: handle_delete(form)

  def handle_key(key, _mods, form) do
    char = if String.length(key) == 1, do: key, else: ""
    form = ensure_focus_valid(form)
    field = Fields.field_atom(form.field)

    form
    |> update_field_text(field, char)
    |> Auth.auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  def handle_backspace(form) do
    form = ensure_focus_valid(form)
    field = Fields.field_atom(form.field)
    current = Map.get(form, field)
    cursor = clamped_cursor(form, current)

    {new_val, cursor} =
      if cursor > 0 do
        {remove_at(current, cursor - 1), cursor - 1}
      else
        {current, cursor}
      end

    %{Map.put(form, field, new_val) | error: nil, cursor: cursor}
    |> Auth.auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  defp handle_delete(form) do
    form = ensure_focus_valid(form)
    field = Fields.field_atom(form.field)
    current = Map.get(form, field)
    cursor = clamped_cursor(form, current)
    new_val = if cursor < String.length(current), do: remove_at(current, cursor), else: current

    %{Map.put(form, field, new_val) | error: nil, cursor: cursor}
    |> Auth.auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  def insert_text(form, text) do
    form = ensure_focus_valid(form)
    field = Fields.field_atom(form.field)
    clean = String.replace(text, "\n", " ")

    form
    |> update_field_text(field, clean)
    |> Auth.auto_detect_mode()
    |> ensure_focus_valid()
    |> ensure_focus_visible()
  end

  defp update_field_text(form, :auth_strategy, text) do
    current = String.trim(form.auth_strategy)

    value =
      cond do
        text == "" -> current
        Auth.complete_strategy?(current) -> text
        true -> current <> text
      end

    %{form | auth_strategy: value, error: nil, cursor: String.length(value)}
  end

  defp update_field_text(form, field, text) do
    current = Map.fetch!(form, field)
    cursor = clamped_cursor(form, current)
    value = insert_at(current, cursor, text)

    %{Map.put(form, field, value) | error: nil, cursor: cursor + String.length(text)}
  end

  defp next_field(form, opts) do
    form = Auth.auto_detect_mode(form)
    ids = Fields.focusable_field_ids(form)
    idx = Enum.find_index(ids, &(&1 == form.field)) || 0
    next = next_id(ids, idx, Keyword.fetch!(opts, :wrap?))

    form =
      if form.field == :name and next == :key do
        auto = auto_fill(form.name)

        %{
          form
          | url: if(blank?(form.url), do: auto.url, else: form.url),
            model: if(blank?(form.model), do: auto.model, else: form.model)
        }
      else
        form
      end

    focus_field(%{form | error: nil}, next)
  end

  defp previous_field(form, opts) do
    form = Auth.auto_detect_mode(form)
    ids = Fields.focusable_field_ids(form)
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

  defp focus_field(form, nil), do: form

  defp focus_field(form, field) do
    value = Map.get(form, Fields.field_atom(field), "")

    %{form | field: field, cursor: String.length(value)}
    |> ensure_focus_visible()
  end

  defp ensure_focus_valid(form) do
    ids = Fields.focusable_field_ids(form)

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
    |> Fields.visible_fields()
    |> Enum.find_index(&(&1.id == field_id))
    |> case do
      nil -> nil
      idx -> {3 + idx * 4, 3 + idx * 4 + 3}
    end
  end

  defp total_line_count(form) do
    field_count = length(Fields.visible_fields(form))
    error_count = if form.error, do: 1, else: 0
    3 + field_count * 4 + error_count + 2
  end

  defp auto_fill(name) do
    case Beamcore.Provider.Registry.get(name) do
      nil -> %{url: "", model: ""}
      info -> %{url: info.base_url || "", model: info.default_model || ""}
    end
  rescue
    _ -> %{url: "", model: ""}
  end

  defp move_cursor(form, amount) do
    form = ensure_focus_valid(form)
    value = Map.get(form, Fields.field_atom(form.field), "")

    %{
      form
      | cursor: (clamped_cursor(form, value) + amount) |> max(0) |> min(String.length(value))
    }
  end

  defp move_cursor_to_end(form) do
    form = ensure_focus_valid(form)
    value = Map.get(form, Fields.field_atom(form.field), "")
    %{form | cursor: String.length(value)}
  end

  defp clamped_cursor(form, value), do: form.cursor |> max(0) |> min(String.length(value))

  defp insert_at(value, cursor, text) do
    String.slice(value, 0, cursor) <> text <> String.slice(value, cursor..-1//1)
  end

  defp remove_at(value, index) do
    String.slice(value, 0, index) <> String.slice(value, (index + 1)..-1//1)
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp shift?(nil), do: false
  defp shift?(mods), do: "shift" in mods
end
