defmodule Beamcore.Agent.Tools.WebGet do
  @moduledoc """
  Tool to fetch content from URLs using HTTP GET requests, optimized for token awareness by cleaning HTML markup.
  """

  @description """
  Fetch an external URL only when policy explicitly allows network access.
  Only HTTP GET requests are supported (e.g. for searching or retrieving information).
  """

  @max_bytes 2_000_000
  @max_cleaned_chars 500_000
  @timeout 30_000

  @default_headers %{
    "User-Agent" =>
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
    "Accept-Language" => "en-US,en;q=0.5",
    "Connection" => "keep-alive"
  }

  def name, do: "web_get"

  def spec do
    %{
      type: "function",
      function: %{
        name: name(),
        description: @description,
        parameters: %{
          type: "object",
          properties: %{
            url: %{
              type: "string",
              description: "The URL to fetch. Must start with http:// or https://."
            },
            headers: %{
              type: "object",
              additionalProperties: %{type: "string"},
              description: "Dictionary of HTTP headers (e.g., {\"Accept\": \"text/html\"})."
            },
            timeout: %{
              type: "integer",
              description: "Timeout in milliseconds. Defaults to 30000 (30 seconds)."
            }
          },
          required: ["url"]
        }
      }
    }
  end

  def execute(params) do
    url = Map.fetch!(params, "url")
    headers = Map.get(params, "headers", %{})
    timeout = Map.get(params, "timeout", @timeout)

    # Validate URL
    if String.starts_with?(url, "http://") || String.starts_with?(url, "https://") do
      # Case-insensitive headers merging
      normalized_defaults =
        Map.new(@default_headers, fn {k, v} -> {String.downcase(k), {k, v}} end)

      merged_headers =
        Enum.reduce(headers, normalized_defaults, fn {k, v}, acc ->
          Map.put(acc, String.downcase(k), {k, v})
        end)

      header_list =
        Enum.map(merged_headers, fn {_lower, {k, v}} ->
          {String.to_charlist(k), String.to_charlist(v)}
        end)

      make_request(url, header_list, timeout)
    else
      "Error: URL must start with http:// or https://"
    end
  end

  defp make_request(url, headers, timeout) do
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), headers}
    http_opts = [timeout: timeout, autoredirect: true]

    case http_client().request(:get, request, http_opts, []) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        raw_body = IO.iodata_to_binary(resp_body)
        raw_size = byte_size(raw_body)

        # Truncate raw body if it exceeds our extreme safety limit before processing
        raw_body =
          if raw_size > @max_bytes do
            binary_part(raw_body, 0, @max_bytes)
          else
            raw_body
          end

        # Check if content type is HTML
        content_type = get_header_value(resp_headers, "content-type")
        is_html = html_content?(content_type, raw_body)

        {cleaned_body, cleaned_size, is_cleaned} =
          if is_html do
            cleaned = clean_html(raw_body, url)
            cleaned_len = byte_size(cleaned)
            {cleaned, cleaned_len, true}
          else
            {raw_body, raw_size, false}
          end

        # Apply maximum character limit to cleaned/final text
        {final_body, final_size, was_truncated} =
          if String.length(cleaned_body) > @max_cleaned_chars do
            truncated = String.slice(cleaned_body, 0, @max_cleaned_chars)
            {truncated, byte_size(truncated), true}
          else
            {cleaned_body, cleaned_size, false}
          end

        formatted_headers =
          Enum.map(resp_headers, fn {key, value} ->
            "#{key}: #{value}"
          end)
          |> Enum.join(", ")

        metadata_str =
          build_metadata(
            status,
            raw_size,
            final_size,
            formatted_headers,
            is_cleaned,
            was_truncated
          )

        """
        #{final_body}

        <web_get_metadata>
        #{metadata_str}
        </web_get_metadata>
        """

      {:error, reason} ->
        "Error: #{inspect(reason)}"
    end
  end

  defp get_header_value(headers, name) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, nil, fn {k, v} ->
      if String.downcase(to_string(k)) == name_lower, do: to_string(v)
    end)
  end

  defp html_content?(nil, body) do
    trimmed = body |> String.trim_leading() |> String.slice(0, 200) |> String.downcase()

    String.starts_with?(trimmed, "<html") || String.starts_with?(trimmed, "<!doctype html") ||
      String.starts_with?(trimmed, "<")
  end

  defp html_content?(content_type, _body) do
    String.contains?(String.downcase(content_type), "html")
  end

  @doc """
  Clean up HTML body and convert to high-fidelity Markdown: strip noise (scripts, styles, SVGs, iframes,
  comments, navigation, footers, forms), format headings, lists, bold/italic, tables, and code blocks,
  resolve relative links and images to absolute URLs, decode entities, and collapse whitespaces while
  preserving code block indentation.
  """
  def clean_html(html, base_url \\ nil) when is_binary(html) do
    html
    # 1. Strip boilerplate/noise tags and contents completely
    |> strip_noise_tags()
    # 2. Convert images to markdown
    |> convert_images(base_url)
    # 3. Convert links to markdown
    |> convert_links(base_url)
    # 4. Convert headings (<h1> - <h6>)
    |> convert_headings()
    # 5. Convert preformatted blocks (<pre>)
    |> convert_pre_blocks()
    # 6. Convert inline styling (<strong>, <b>, <em>, <i>, <code>)
    |> convert_inline_styles()
    # 6b. Collapse whitespace/newlines between table-related tags
    |> collapse_table_whitespace()
    # 7. Convert structural elements (<li>, <p>, <br>, <tr>, <td>, <th>, <div>)
    |> convert_structural_tags()
    # 8. Strip remaining HTML tags safely (keeping math symbols like < or >)
    |> strip_remaining_tags()
    # 9. Decode HTML entities (named and numeric)
    |> decode_entities()
    # 10. Collapse whitespace and consecutive blank lines, preserving code block formatting
    |> collapse_whitespace_preserving_code()
  end

  defp strip_noise_tags(html) do
    noise_tags = [
      "script",
      "style",
      "svg",
      "iframe",
      "noscript",
      "canvas",
      "nav",
      "footer",
      "aside",
      "form",
      "button",
      "select",
      "option",
      "dialog",
      "map",
      "area",
      "track"
    ]

    cleaned =
      Enum.reduce(noise_tags, html, fn tag, acc ->
        String.replace(acc, ~r/<#{tag}\b[^>]*>.*?<\/#{tag}>/is, "")
      end)

    # Strip HTML comments
    String.replace(cleaned, ~r/<!--.*?-->/s, "")
  end

  defp convert_images(html, base_url) do
    Regex.replace(~r/<img\b([^>]*)\/?>/is, html, fn _, attrs ->
      src =
        case Regex.run(~r/src=["'\x27]?([^"'\x27\s>]+)["'\x27]?/i, attrs) do
          [_, s] -> s
          nil -> nil
        end

      alt =
        case Regex.run(~r/alt=["'\x27]([^"'\x27]*)["'\x27]/i, attrs) do
          [_, a] ->
            a

          nil ->
            case Regex.run(~r/alt=([^\s>]+)/i, attrs) do
              [_, a] -> a
              nil -> ""
            end
        end

      if src do
        resolved_src =
          if base_url && not String.starts_with?(src, "data:") do
            try do
              URI.merge(base_url, src) |> URI.to_string()
            rescue
              _ -> src
            end
          else
            src
          end

        "![#{alt}](#{resolved_src})"
      else
        ""
      end
    end)
  end

  defp convert_links(html, base_url) do
    Regex.replace(~r/<a\b([^>]*)>(.*?)<\/a>/is, html, fn _, attrs, text ->
      case Regex.run(~r/href=["'\x27]?([^"'\x27\s>]+)["'\x27]?/i, attrs) do
        [_, href] ->
          # Ignore internal javascript, anchor fragments, email/phone links
          if String.starts_with?(href, "javascript:") or
               String.starts_with?(href, "#") or
               String.starts_with?(href, "mailto:") or
               String.starts_with?(href, "tel:") do
            text
          else
            resolved_href =
              if base_url do
                try do
                  URI.merge(base_url, href) |> URI.to_string()
                rescue
                  _ -> href
                end
              else
                href
              end

            "[#{text}](#{resolved_href})"
          end

        nil ->
          text
      end
    end)
  end

  defp convert_headings(html) do
    Enum.reduce(1..6, html, fn level, acc ->
      Regex.replace(~r/<h#{level}\b[^>]*>(.*?)<\/h#{level}>/is, acc, fn _, content ->
        hashes = String.duplicate("#", level)
        "\n\n#{hashes} #{content}\n\n"
      end)
    end)
  end

  defp convert_pre_blocks(html) do
    Regex.replace(~r/<pre\b[^>]*>(.*?)<\/pre>/is, html, fn _, content ->
      # Clean out any nested code tags
      clean_pre = String.replace(content, ~r/<\/?code\b[^>]*>/is, "")
      "\n\n```\n#{clean_pre}\n```\n\n"
    end)
  end

  defp convert_inline_styles(html) do
    html = Regex.replace(~r/<(strong|b)\b[^>]*>(.*?)<\/\1>/is, html, "**\\2**")
    html = Regex.replace(~r/<(em|i)\b[^>]*>(.*?)<\/\1>/is, html, "*\\2*")
    Regex.replace(~r/<code>(.*?)<\/code>/is, html, "`\\1`")
  end

  defp convert_structural_tags(html) do
    html
    |> String.replace(~r/<li\b[^>]*>/i, "\n* ")
    |> String.replace(~r/<\/li>/i, "")
    |> String.replace(~r/<\/?p\b[^>]*>/i, "\n\n")
    |> String.replace(~r/<br\b[^>]*>/i, "\n")
    |> String.replace(~r/<\/?tr\b[^>]*>/i, "\n")
    |> String.replace(~r/<\/?(td|th)\b[^>]*>/i, " | ")
    |> String.replace(~r/<\/?div\b[^>]*>/i, "\n")
  end

  defp collapse_table_whitespace(html) do
    pattern =
      ~r/(<\/?(?:table|thead|tbody|tr|td|th)\b[^>]*>)\s+(?=(?:<\/?(?:table|thead|tbody|tr|td|th)\b[^>]*>))/is

    Regex.replace(pattern, html, "\\1")
  end

  defp strip_remaining_tags(html) do
    # Only matches actual valid HTML-like tags, avoiding stray < and > symbols
    Regex.replace(~r/<\/?[a-zA-Z][^>]*>/, html, "")
  end

  defp decode_entities(text) do
    text
    # 1. Decode standard named entities
    |> decode_named_entities()
    # 2. Decode hexadecimal numeric entities (e.g., &#x2014;)
    |> decode_hex_entities()
    # 3. Decode decimal numeric entities (e.g., &#8212;)
    |> decode_dec_entities()
  end

  defp decode_named_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&ldquo;", "“")
    |> String.replace("&rdquo;", "”")
    |> String.replace("&lsquo;", "‘")
    |> String.replace("&rsquo;", "’")
    |> String.replace("&ndash;", "–")
    |> String.replace("&mdash;", "—")
    |> String.replace("&copy;", "©")
    |> String.replace("&reg;", "®")
    |> String.replace("&trade;", "™")
    |> String.replace("&bull;", "•")
    |> String.replace("&hellip;", "…")
    |> String.replace("&middot;", "·")
    |> String.replace("&times;", "×")
    |> String.replace("&divide;", "÷")
    |> String.replace("&para;", "¶")
    |> String.replace("&sect;", "§")
    |> String.replace("&deg;", "°")
  end

  defp decode_hex_entities(text) do
    Regex.replace(~r/&#[xX]([0-9a-fA-F]+);/, text, fn _, hex ->
      case Integer.parse(hex, 16) do
        {code_point, ""} ->
          try do
            List.to_string([code_point])
          rescue
            _ -> ""
          end

        _ ->
          ""
      end
    end)
  end

  defp decode_dec_entities(text) do
    Regex.replace(~r/&#(\d+);/, text, fn _, dec ->
      case Integer.parse(dec, 10) do
        {code_point, ""} ->
          try do
            List.to_string([code_point])
          rescue
            _ -> ""
          end

        _ ->
          ""
      end
    end)
  end

  defp collapse_whitespace_preserving_code(text) do
    # 1. Extract all markdown code blocks and replace with placeholders
    {text_with_placeholders, blocks} =
      Regex.scan(~r/```.*?```/s, text)
      |> Enum.map(&hd/1)
      |> Enum.with_index()
      |> Enum.reduce({text, %{}}, fn {block, idx}, {current_text, acc_map} ->
        placeholder = "__CODE_BLOCK_PLACEHOLDER_#{idx}__"
        updated_text = String.replace(current_text, block, placeholder, global: false)
        {updated_text, Map.put(acc_map, placeholder, block)}
      end)

    # 2. Collapse consecutive spaces, tabs, and empty lines on standard text
    collapsed =
      text_with_placeholders
      # Collapse tabs and multiple spaces to a single space
      |> String.replace(~r/[ \t]+/m, " ")
      # Split by newline, trim margins, and collapse excessive empty lines
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.chunk_by(&(&1 == ""))
      |> Enum.flat_map(fn
        ["" | _] -> [""]
        lines -> lines
      end)
      |> Enum.join("\n")
      |> String.trim()

    # 3. Restore raw code blocks in their original placeholders, fully preserving spacing/indentation
    Enum.reduce(blocks, collapsed, fn {placeholder, block}, acc ->
      String.replace(acc, placeholder, block, global: false)
    end)
  end

  defp build_metadata(status, raw_size, final_size, headers, is_cleaned, was_truncated) do
    savings =
      if raw_size > 0 and is_cleaned do
        reduction = (1.0 - final_size / raw_size) * 100
        " (cleaned, #{Float.round(reduction, 1)}% token reduction)"
      else
        ""
      end

    truncation_note =
      if was_truncated do
        ", truncated to #{@max_cleaned_chars} chars"
      else
        ""
      end

    "Status: #{status}, Size: #{final_size} bytes / #{raw_size} raw bytes#{savings}#{truncation_note}, Headers: #{headers}"
  end

  defp http_client do
    Application.get_env(:agent, :http_client, Beamcore.Agent.Tools.WebGet.HTTPCWrapper)
  end
end

defmodule Beamcore.Agent.Tools.WebGet.HTTPCWrapper do
  @moduledoc """
  Production HTTP client wrapper for :httpc.
  """
  def request(method, request, http_opts, opts) do
    :httpc.request(method, request, http_opts, opts)
  end
end
