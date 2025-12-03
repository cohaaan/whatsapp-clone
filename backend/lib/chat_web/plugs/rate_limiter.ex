defmodule ChatWeb.Plugs.RateLimiter do
  @moduledoc """
  Plug for rate limiting HTTP requests.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    # Extract IP address
    ip_address = get_ip_address(conn)

    case Chat.RateLimiter.check_ip_rate(ip_address) do
      {:allow, _count} ->
        conn

      {:deny, limit} ->
        Logger.warning("Rate limit exceeded for IP: #{ip_address}")

        # Calculate retry-after (time until window resets)
        retry_after = calculate_retry_after()

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_header("x-ratelimit-limit", to_string(limit))
        |> put_resp_header("x-ratelimit-remaining", "0")
        |> send_resp(429, Jason.encode!(%{error: "rate_limit_exceeded", retry_after: retry_after}))
        |> halt()
    end
  end

  defp get_ip_address(conn) do
    # Check for X-Forwarded-For header (from load balancer/proxy)
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        ip
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to remote_ip
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  defp calculate_retry_after do
    # Return seconds until next minute (simplified)
    60 - rem(:os.system_time(:second), 60)
  end
end
