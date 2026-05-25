defmodule Beamcore.Agent.Tools.WebGetTest do
  use ExUnit.Case

  alias Beamcore.Agent.Tools.WebGet

  defmodule MockHTTPClient do
    def request(:get, {_url, _headers}, _http_opts, _opts) do
      body = "<html><body><main>Hello from mock</main></body></html>"

      {:ok,
       {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"text/html"}],
        String.to_charlist(body)}}
    end
  end

  setup do
    previous = Application.get_env(:agent, :http_client)
    Application.put_env(:agent, :http_client, MockHTTPClient)

    on_exit(fn ->
      if previous do
        Application.put_env(:agent, :http_client, previous)
      else
        Application.delete_env(:agent, :http_client)
      end
    end)
  end

  test "web_get requires a url parameter" do
    assert_raise KeyError, fn ->
      WebGet.execute(%{})
    end
  end

  test "web_get validates url protocol" do
    result = WebGet.execute(%{"url" => "ftp://example.com"})
    assert result == "Error: URL must start with http:// or https://"
  end

  test "web_get executes a valid get request" do
    result = WebGet.execute(%{"url" => "https://example.test/get"})

    assert String.contains?(result, "Status: 200")
    assert String.contains?(result, "Hello from mock")
    assert String.contains?(result, "<web_get_metadata>")
  end

  test "clean_html removes script, style, svg, and comment elements" do
    html = """
    <!DOCTYPE html>
    <html>
      <head>
        <title>Test Page</title>
        <style>
          body { color: red; }
        </style>
        <script>
          console.log("hello");
        </script>
      </head>
      <body>
        <!-- This is a comment -->
        <h1>Hello World</h1>
        <p>This is a paragraph with <svg><path d="M0 0h10v10H0z"/></svg> an inline SVG.</p>
      </body>
    </html>
    """

    cleaned = WebGet.clean_html(html)

    # Verify script, style, svg, and comments are removed
    refute String.contains?(cleaned, "body { color: red; }")
    refute String.contains?(cleaned, "console.log")
    refute String.contains?(cleaned, "This is a comment")
    refute String.contains?(cleaned, "<path")
    refute String.contains?(cleaned, "svg")

    # Verify text content remains and is clean
    assert String.contains?(cleaned, "Hello World")
    assert String.contains?(cleaned, "This is a paragraph with an inline SVG.")
  end

  test "clean_html decodes html entities" do
    html = "<p>It&apos;s a &quot;beautiful&quot; day &amp; &nbsp; night &lt; &gt;</p>"
    cleaned = WebGet.clean_html(html)
    assert cleaned == "It's a \"beautiful\" day & night < >"
  end

  test "clean_html collapses consecutive whitespace and empty lines" do
    html = """
    <div>
      First Line


      Second   Line   with   spaces.
    </div>
    """

    cleaned = WebGet.clean_html(html)
    assert cleaned == "First Line\n\nSecond Line with spaces."
  end

  # NEW TESTS FOR PREMIUM UPGRADED CAPABILITIES

  test "clean_html removes navigation, footer, aside, form, and button elements" do
    html = """
    <div>
      <nav>
        <a href="/home">Home</a>
        <a href="/about">About Us</a>
      </nav>
      <aside>
        <p>Advertisement banner</p>
      </aside>
      <main>
        <h1>Actual Article Title</h1>
        <p>Main content of the article goes here.</p>
        <form action="/subscribe">
          <input type="email" placeholder="Your email" />
          <button type="submit">Subscribe</button>
        </form>
      </main>
      <footer>
        <p>&copy; 2026 Beamcore Corp. All rights reserved.</p>
        <a href="/privacy">Privacy Policy</a>
      </footer>
    </div>
    """

    cleaned = WebGet.clean_html(html)

    # Verify navigation, sidebars, forms, and footers are stripped
    refute String.contains?(cleaned, "Home")
    refute String.contains?(cleaned, "About Us")
    refute String.contains?(cleaned, "Advertisement banner")
    refute String.contains?(cleaned, "Subscribe")
    refute String.contains?(cleaned, "Beamcore Corp")
    refute String.contains?(cleaned, "Privacy Policy")

    # Verify the main content is fully retained
    assert String.contains?(cleaned, "# Actual Article Title")
    assert String.contains?(cleaned, "Main content of the article goes here.")
  end

  test "clean_html resolves relative links and images against base URL" do
    html = """
    <div>
      <p>Go to <a href="/docs/guide.html">documentation</a> or <a href="http://external.com">external site</a>.</p>
      <img src="logo.png" alt="Company Logo" />
      <img src="https://example.com/banner.jpg" alt="Banner" />
    </div>
    """

    base_url = "https://beamcore.org/blog/index.html"
    cleaned = WebGet.clean_html(html, base_url)

    # Verify relative paths are resolved to absolute URLs
    assert String.contains?(cleaned, "[documentation](https://beamcore.org/docs/guide.html)")
    assert String.contains?(cleaned, "![Company Logo](https://beamcore.org/blog/logo.png)")

    # Verify absolute URLs are left untouched
    assert String.contains?(cleaned, "[external site](http://external.com)")
    assert String.contains?(cleaned, "![Banner](https://example.com/banner.jpg)")
  end

  test "clean_html converts HTML headings, inline formatting, and structures to high-fidelity Markdown" do
    html = """
    <div>
      <h1>Heading One</h1>
      <h2>Heading Two</h2>
      <p>Here is some <strong>bold</strong> and <em>italic</em> text.</p>
      <ul>
        <li>List Item 1</li>
        <li>List Item 2</li>
      </ul>
      <table>
        <tr>
          <th>Header 1</th>
          <th>Header 2</th>
        </tr>
        <tr>
          <td>Value 1</td>
          <td>Value 2</td>
        </tr>
      </table>
    </div>
    """

    cleaned = WebGet.clean_html(html)

    # Verify headings
    assert String.contains?(cleaned, "# Heading One")
    assert String.contains?(cleaned, "## Heading Two")

    # Verify inline styles
    assert String.contains?(cleaned, "**bold**")
    assert String.contains?(cleaned, "*italic*")

    # Verify lists
    assert String.contains?(cleaned, "* List Item 1")
    assert String.contains?(cleaned, "* List Item 2")

    # Verify table row formatting
    assert String.contains?(cleaned, "| Header 1 | | Header 2 |")
    assert String.contains?(cleaned, "| Value 1 | | Value 2 |")
  end

  test "clean_html decodes premium named and decimal/hex numeric HTML entities" do
    html = """
    <div>
      <p>Smart quotes: &ldquo;Hello&rdquo; and &lsquo;World&rsquo;</p>
      <p>Dashes and symbols: &ndash; &mdash; &copy; &reg; &trade; &bull; &hellip;</p>
      <p>Hex decimal code points: &#x2014; &#x2605;</p>
      <p>Decimal code points: &#8212; &#9733;</p>
    </div>
    """

    cleaned = WebGet.clean_html(html)

    assert String.contains?(cleaned, "“Hello”")
    assert String.contains?(cleaned, "‘World’")
    assert String.contains?(cleaned, "– — © ® ™ • …")
    assert String.contains?(cleaned, "— ★")
  end

  test "clean_html preserves exact spacing and indentation inside code blocks" do
    html = """
    <div>
      <h1>Snippet</h1>
      <pre><code>def test_fun(x) do
      if x < 10 do
        # Keeps indentation!
        IO.puts "small"
      else
        IO.puts "large"
      end
    end</code></pre>
      <p>Next paragraph.</p>
    </div>
    """

    cleaned = WebGet.clean_html(html)

    expected_code =
      """
      ```
      def test_fun(x) do
        if x < 10 do
          # Keeps indentation!
          IO.puts "small"
        else
          IO.puts "large"
        end
      end
      ```
      """
      |> String.trim_trailing()

    assert String.contains?(cleaned, expected_code)

    # Verify that the stray < symbol in the code snippet is NOT stripped as a tag
    assert String.contains?(cleaned, "x < 10")
  end
end
