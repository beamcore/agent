defmodule Beamcore.TUI.Components.Providers.Form do
  @moduledoc false

  alias ExRatatui.Text.{Line, Span}

  @field_width 54

  defstruct field: :name,
            name: "",
            key: "",
            url: "",
            model: "",
            token_url: "",
            mode: :openai,
            error: nil

  def new, do: %__MODULE__{}

  def render(form, muted, accent, input_style) do
    mode_label = if form.mode == :oauth2, do: "OAuth2", else: "OpenAI"
    mode_style = if form.mode == :oauth2, do: accent, else: muted

    fields = [:name, :key, :url, :model, :token_url]

    rows =
      Enum.flat_map(fields, fn f ->
        value = field_value(form, f)
        active? = form.field == f
        cursor = if active?, do: "█", else: ""
        label_s = if active?, do: accent, else: muted
        req = if required?(f, form.mode), do: " *", else: ""
        display = truncate_display(value <> cursor, @field_width)
        padded = String.pad_trailing(display, @field_width)

        [
          %Line{
            spans: [
              %Span{content: "  #{field_label(f)}#{req}", style: label_s}
            ]
          },
          %Line{
            spans: [
              %Span{content: "  ┌#{String.duplicate("─", @field_width + 2)}┐", style: muted}
            ]
          },
          %Line{
            spans: [
              %Span{content: "  │ #{padded} │", style: input_style}
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
  end

  def handle_key("tab", _mods, form), do: next_field(form)

  def handle_key("down", _mods, form), do: next_field(form)

  def handle_key("up", _mods, form) do
    form = auto_detect_mode(form)
    fields = [:name, :key, :url, :model, :token_url]
    idx = Enum.find_index(fields, &(&1 == form.field)) || 0
    prev = Enum.at(fields, rem(idx - 1 + length(fields), length(fields)))
    %{form | field: prev, error: nil}
  end

  def handle_key("enter", _mods, form) do
    form = auto_detect_mode(form)

    cond do
      form.name == "" ->
        %{form | field: :name, error: "name required"}

      form.key == "" ->
        %{form | field: :key, error: "key required"}

      form.mode == :oauth2 and form.token_url == "" ->
        %{form | field: :token_url, error: "token url required for OAuth2"}

      true ->
        config =
          %{
            "api_key" => form.key,
            "base_url" => if(form.url != "", do: form.url, else: nil),
            "default_model" => if(form.model != "", do: form.model, else: nil),
            "token_url" => if(form.token_url != "", do: form.token_url, else: nil)
          }
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> Map.new()

        Beamcore.Config.put_provider(form.name, config)
        {:saved, form}
    end
  end

  def handle_key("esc", _mods, form), do: {:cancel, form}

  def handle_key(key, _mods, form) do
    char = if String.length(key) == 1, do: key, else: ""
    field = field_atom(form.field)
    %{Map.update!(form, field, &(&1 <> char)) | error: nil}
  end

  def handle_backspace(form) do
    field = field_atom(form.field)
    current = Map.get(form, field)
    new_val = if String.length(current) > 0, do: String.slice(current, 0..-2//1), else: current
    %{Map.put(form, field, new_val) | error: nil}
  end

  def insert_text(form, text) do
    field = field_atom(form.field)
    clean = String.replace(text, "\n", " ")
    %{Map.update!(form, field, &(&1 <> clean)) | error: nil}
  end

  # -- Private -----------------------------------------------------------------

  defp next_field(form) do
    form = auto_detect_mode(form)
    fields = [:name, :key, :url, :model, :token_url]
    idx = Enum.find_index(fields, &(&1 == form.field)) || 0
    next = Enum.at(fields, rem(idx + 1, length(fields)))

    form =
      if form.field == :name and next == :key do
        auto = auto_fill(form.name)
        %{form | url: form.url || auto.url, model: form.model || auto.model}
      else
        form
      end

    %{form | field: next, error: nil}
  end

  defp field_label(:name), do: "name"
  defp field_label(:key), do: "api key"
  defp field_label(:url), do: "base url"
  defp field_label(:model), do: "model"
  defp field_label(:token_url), do: "token url"

  defp required?(:name, _), do: true
  defp required?(:key, _), do: true
  defp required?(:token_url, :oauth2), do: true
  defp required?(_, _), do: false

  defp field_value(form, :name), do: form.name
  defp field_value(form, :key), do: mask(form.key)
  defp field_value(form, :url), do: form.url
  defp field_value(form, :model), do: form.model
  defp field_value(form, :token_url), do: form.token_url

  defp field_atom(:name), do: :name
  defp field_atom(:key), do: :key
  defp field_atom(:url), do: :url
  defp field_atom(:model), do: :model
  defp field_atom(:token_url), do: :token_url

  defp auto_detect_mode(form) do
    if form.token_url != "", do: %{form | mode: :oauth2}, else: %{form | mode: :openai}
  end

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
end
