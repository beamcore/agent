defmodule Beamcore.Proxy do
  @moduledoc """
  HTTP proxy configuration from environment variables.

  Reads standard proxy environment variables (`HTTP_PROXY`, `HTTPS_PROXY`,
  `NO_PROXY`) and provides configuration for both Erlang `:httpc` and
  Finch/Mint HTTP clients.

  ## Supported environment variables

    * `HTTPS_PROXY` / `https_proxy` — proxy URL for HTTPS connections (preferred)
    * `HTTP_PROXY` / `http_proxy` — proxy URL for HTTP connections (fallback for HTTPS)
    * `NO_PROXY` / `no_proxy` — comma-separated list of hosts/domains to bypass

  ## Proxy URL format

      http://host:port
      http://user:password@host:port
      socks5://host:port
  """

  @doc """
  Returns the parsed proxy URL for HTTPS connections, or nil if not set.

  Checks `HTTPS_PROXY` first, then falls back to `HTTP_PROXY`.
  """
  @spec https_proxy() :: URI.t() | nil
  def https_proxy do
    (read_env("HTTPS_PROXY") || read_env("HTTP_PROXY"))
    |> parse_proxy_url()
  end

  @doc """
  Returns the parsed proxy URL for HTTP connections, or nil if not set.
  """
  @spec http_proxy() :: URI.t() | nil
  def http_proxy do
    read_env("HTTP_PROXY")
    |> parse_proxy_url()
  end

  @doc """
  Returns the list of hosts/domains that should bypass the proxy.
  """
  @spec no_proxy_list() :: [String.t()]
  def no_proxy_list do
    case read_env("NO_PROXY") do
      nil -> []
      value -> value |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  Returns true if the given URL's host matches the NO_PROXY list.
  """
  @spec bypassed?(String.t()) :: boolean()
  def bypassed?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host_bypassed?(String.downcase(host), no_proxy_list())

      _ ->
        false
    end
  end

  defp host_bypassed?(_host, []), do: false

  defp host_bypassed?(host, [pattern | rest]) do
    pattern = pattern |> String.downcase() |> String.trim_leading(".")

    if host == pattern or String.ends_with?(host, "." <> pattern) do
      true
    else
      host_bypassed?(host, rest)
    end
  end

  @doc """
  Returns true if a proxy is configured for HTTPS.
  """
  @spec configured?() :: boolean()
  def configured? do
    https_proxy() != nil
  end

  @doc """
  Returns Finch pool configuration with proxy settings.

  Used when starting a custom Finch pool that routes through the proxy.
  Returns nil if no proxy is configured.
  """
  @spec finch_conn_opts() :: keyword() | nil
  def finch_conn_opts do
    case https_proxy() do
      nil ->
        nil

      %URI{host: host, port: port, scheme: scheme} ->
        proxy_scheme = if scheme == "https", do: :https, else: :http
        [proxy: {proxy_scheme, host, port || default_port(scheme), proxy_headers()}]
    end
  end

  @doc """
  Configures Erlang `:httpc` with proxy settings.

  Call this during application startup to enable proxy for all `:httpc` requests.
  """
  @spec configure_httpc!() :: :ok
  def configure_httpc! do
    case https_proxy() do
      nil ->
        :ok

      %URI{host: host, port: port, scheme: scheme} ->
        proxy_host = to_charlist(host)
        proxy_port = port || default_port(scheme)

        no_proxy =
          no_proxy_list()
          |> Enum.map(&to_charlist/1)

        :httpc.set_options([
          {:proxy, {{proxy_host, proxy_port}, no_proxy}}
        ])

        :ok
    end
  end

  @doc """
  Returns a human-readable description of the configured proxy, or nil.
  """
  @spec describe() :: String.t() | nil
  def describe do
    case https_proxy() do
      nil -> nil
      %URI{host: host, port: port, scheme: scheme} -> "#{scheme}://#{host}:#{port || default_port(scheme)}"
    end
  end

  # --- Private ---

  defp read_env(name) do
    # Check uppercase first, then lowercase (standard convention)
    case System.get_env(name) do
      nil -> System.get_env(String.downcase(name))
      "" -> System.get_env(String.downcase(name))
      value -> value
    end
    |> case do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  defp parse_proxy_url(nil), do: nil

  defp parse_proxy_url(url) when is_binary(url) do
    uri = URI.parse(url)

    if uri.host && uri.host != "" do
      uri
    else
      nil
    end
  end

  defp default_port("https"), do: 443
  defp default_port(_), do: 80

  defp proxy_headers do
    case https_proxy() do
      %URI{userinfo: userinfo} when is_binary(userinfo) and userinfo != "" ->
        encoded = Base.encode64(userinfo)
        [{"proxy-authorization", "Basic #{encoded}"}]

      _ ->
        []
    end
  end
end
