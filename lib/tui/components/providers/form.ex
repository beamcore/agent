defmodule Beamcore.TUI.Components.Providers.Form do
  @moduledoc false

  alias ExRatatui.Text.{Line, Span}

  @field_width 60

  defstruct field: :name,
            name: "",
            key: "",
            url: "",
            model: ""

  def new do
    %__MODULE__{}
  end

  def render(form, muted, accent, input_style) do
    sep = String.duplicate("─", 40)

    field = fn label, value, active?, required? ->
      cursor = if active?, do: "█", else: ""
      label_s = if active?, do: accent, else: muted
      req = if required?, do: " *", else: ""
      display = truncate_display(value <> cursor, @field_width)
      padded = String.pad_trailing(display, @field_width)

      [
        %Line{spans: [%Span{content: "  #{label}#{req}", style: label_s}]},
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
    end

    [
      %Line{spans: [%Span{content: ""}]},
      %Line{spans: [%Span{content: "  Add Provider", style: accent}]},
      %Line{spans: [%Span{content: "  #{sep}", style: muted}]},
      %Line{spans: [%Span{content: ""}]}
    ] ++
      field.("name", form.name, form.field == :name, true) ++
      [%Line{spans: [%Span{content: ""}]}] ++
      field.("api key", mask(form.key), form.field == :key, true) ++
      [%Line{spans: [%Span{content: ""}]}] ++
      field.("base url", form.url, form.field == :url, false) ++
      [%Line{spans: [%Span{content: ""}]}] ++
      field.("model", form.model, form.field == :model, false) ++
      [
        %Line{spans: [%Span{content: ""}]},
        %Line{spans: [%Span{content: "  #{sep}", style: muted}]},
        %Line{
          spans: [
            %Span{content: "  tab", style: accent},
            %Span{content: " next   ", style: muted},
            %Span{content: "enter", style: accent},
            %Span{content: " save   ", style: muted},
            %Span{content: "esc", style: accent},
            %Span{content: " cancel", style: muted}
          ]
        }
      ]
  end

  def handle_key("tab", _mods, form) do
    {next, form} =
      case form.field do
        :name ->
          auto = auto_fill(form.name)
          {:key, %{form | url: form.url || auto.url, model: form.model || auto.model}}

        :key ->
          {:url, form}

        :url ->
          {:model, form}

        :model ->
          {:name, form}
      end

    %{form | field: next}
  end

  def handle_key("enter", _mods, form) do
    if form.name != "" and form.key != "" do
      config =
        %{
          "api_key" => form.key,
          "base_url" => if(form.url != "", do: form.url, else: nil),
          "default_model" => if(form.model != "", do: form.model, else: nil)
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      Beamcore.Config.put_provider(form.name, config)
      {:saved, form}
    else
      {:error, form}
    end
  end

  def handle_key("esc", _mods, form), do: {:cancel, form}

  def handle_key(key, _mods, form) do
    char = if String.length(key) == 1, do: key, else: ""
    field = field_atom(form.field)
    Map.update!(form, field, &(&1 <> char))
  end

  def handle_backspace(form) do
    field = field_atom(form.field)
    current = Map.get(form, field)

    new_val =
      if String.length(current) > 0,
        do: String.slice(current, 0..-2//1),
        else: current

    Map.put(form, field, new_val)
  end

  def insert_text(form, text) do
    field = field_atom(form.field)
    clean = String.replace(text, "\n", " ")
    Map.update!(form, field, &(&1 <> clean))
  end

  defp field_atom(:name), do: :name
  defp field_atom(:key), do: :key
  defp field_atom(:url), do: :url
  defp field_atom(:model), do: :model

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
    if String.length(text) <= max_len,
      do: text,
      else: String.slice(text, 0, max_len - 1) <> "…"
  end
end
