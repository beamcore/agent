defmodule Beamcore.TUI.Components.Providers.Form.Renderer do
  @moduledoc false

  alias Beamcore.TUI.Components.Providers.Form.{Auth, Fields}
  alias ExRatatui.Text.{Line, Span}

  @field_width 54

  def render(form, muted, accent, input_style, visible_rows \\ nil) do
    mode_label = Auth.strategy_label(form.mode)

    mode_style =
      if form.mode in [:oauth2_client_credentials, :google_adc], do: accent, else: muted

    rows =
      form
      |> Fields.visible_fields()
      |> Enum.flat_map(&field_rows(&1, form, muted, accent, input_style))

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

  defp field_rows(field, form, muted, accent, input_style) do
    id = field.id
    value = field_value(form, id)
    active? = form.field == id
    cursor = if active?, do: "█", else: ""
    label_style = if active?, do: accent, else: muted
    input_style = if active?, do: accent, else: input_style
    required = if Fields.required?(field, form.mode), do: " *", else: ""
    display = truncate_display(value <> cursor, @field_width)
    padded = String.pad_trailing(display, @field_width)

    [
      %Line{spans: [%Span{content: "  #{field.label}#{required}", style: label_style}]},
      %Line{
        spans: [%Span{content: "  ┌#{String.duplicate("─", @field_width + 2)}┐", style: muted}]
      },
      %Line{spans: [%Span{content: "  │ #{padded} │", style: input_style}]},
      %Line{
        spans: [%Span{content: "  └#{String.duplicate("─", @field_width + 2)}┘", style: muted}]
      }
    ]
  end

  defp field_value(form, :key), do: mask(form.key)
  defp field_value(form, :client_secret), do: mask(form.client_secret)
  defp field_value(form, field), do: Map.get(form, field, "")

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

  defp scroll_lines(lines, offset, visible_rows) do
    if length(lines) > visible_rows do
      Enum.slice(lines, offset, visible_rows)
    else
      lines
    end
  end
end
