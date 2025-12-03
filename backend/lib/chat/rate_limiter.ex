defmodule Chat.RateLimiter do
  @moduledoc """
  Rate limiting using Hammer.

  Limits:
  - Per user: 60 messages/minute
  - Per device: 30 messages/minute
  - Per IP (unauthenticated): 100 requests/minute
  """

  @user_limit 60
  @device_limit 30
  @ip_limit 100
  @window_ms :timer.minutes(1)

  @doc """
  Check message rate limit for both user and device.
  Returns {:allow, count} or {:deny, limit}.
  """
  def check_message_rate(user_id, device_id) do
    user_key = "msg:user:#{user_id}"
    device_key = "msg:device:#{device_id}"

    # Check both user and device limits
    with {:allow, _} <- Hammer.check_rate(user_key, @window_ms, @user_limit),
         {:allow, _} <- Hammer.check_rate(device_key, @window_ms, @device_limit) do
      {:allow, 1}
    else
      {:deny, limit} -> {:deny, limit}
    end
  end

  @doc """
  Check API rate limit for unauthenticated requests by IP.
  """
  def check_ip_rate(ip_address) do
    key = "api:ip:#{ip_address}"
    Hammer.check_rate(key, @window_ms, @ip_limit)
  end

  @doc """
  Check rate limit for OTP requests (3 per hour per phone).
  """
  def check_otp_request_rate(phone_hash) do
    key = "otp:request:#{phone_hash}"
    window = :timer.hours(1)
    limit = 3

    Hammer.check_rate(key, window, limit)
  end

  @doc """
  Check rate limit for OTP verification attempts (5 per 5 min per phone).
  """
  def check_otp_verify_rate(phone_hash) do
    key = "otp:verify:#{phone_hash}"
    window = :timer.minutes(5)
    limit = 5

    Hammer.check_rate(key, window, limit)
  end

  @doc """
  Check rate limit for prekey uploads (10 per minute per user).
  """
  def check_prekey_upload_rate(user_id) do
    key = "prekey:upload:#{user_id}"
    Hammer.check_rate(key, @window_ms, 10)
  end
end
