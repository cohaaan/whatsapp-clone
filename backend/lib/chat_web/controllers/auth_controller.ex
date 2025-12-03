defmodule ChatWeb.AuthController do
  use ChatWeb, :controller

  alias Chat.{Auth, Accounts, RateLimiter}

  require Logger

  @doc """
  Request OTP code.
  POST /api/auth/request_otp
  Body: {"phone_number": "+1234567890"}
  """
  def request_otp(conn, %{"phone_number" => phone_number}) do
    # Normalize phone
    normalized_phone = normalize_phone(phone_number)
    phone_hash = hash_phone(normalized_phone)

    # Rate limiting: 3 requests per hour
    case RateLimiter.check_otp_request_rate(phone_hash) do
      {:allow, _} ->
        # Generate and store OTP
        otp = Auth.generate_otp()
        :ok = Auth.store_otp(normalized_phone, otp)

        # Send OTP via SMS
        case Auth.send_otp_sms(phone_number, otp) do
          {:ok, _} ->
            json(conn, %{
              success: true,
              message: "OTP sent to #{phone_number}"
            })

          {:error, reason} ->
            Logger.error("Failed to send OTP: #{inspect(reason)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{error: "failed_to_send_otp"})
        end

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limit_exceeded", retry_after: 3600})
    end
  end

  @doc """
  Verify OTP and register/login.
  POST /api/auth/verify_otp
  Body: {"phone_number": "+1234567890", "otp": "123456", "platform": "ios", "device_name": "iPhone 14"}
  """
  def verify_otp(conn, %{
        "phone_number" => phone_number,
        "otp" => otp,
        "platform" => platform,
        "device_name" => device_name
      }) do
    normalized_phone = normalize_phone(phone_number)
    phone_hash = hash_phone(normalized_phone)

    # Rate limiting: 5 attempts per 5 minutes
    case RateLimiter.check_otp_verify_rate(phone_hash) do
      {:allow, _} ->
        # Verify OTP
        case Auth.verify_otp(normalized_phone, otp) do
          :ok ->
            # Get or create user
            {:ok, user} = Accounts.get_or_create_user(phone_number)

            # Create device
            {:ok, device} = Accounts.create_device(%{
              user_id: user.id,
              platform: platform,
              device_name: device_name
            })

            # Generate tokens
            {:ok, access_token} = Auth.generate_access_token(user.id, device.id)
            {:ok, refresh_token} = Auth.generate_refresh_token(user.id, device.id)

            # Store refresh token session
            {:ok, _session} = Auth.create_device_session(device.id, refresh_token)

            json(conn, %{
              success: true,
              user_id: user.id,
              device_id: device.id,
              access_token: access_token,
              refresh_token: refresh_token,
              expires_in: 900  # 15 minutes
            })

          {:error, :expired} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "otp_expired"})

          {:error, :invalid_code} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "invalid_otp"})

          {:error, :not_found} ->
            conn
            |> put_status(:bad_request)
            |> json(%{error: "otp_not_found"})
        end

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limit_exceeded", retry_after: 300})
    end
  end

  @doc """
  Refresh access token using refresh token.
  POST /api/auth/refresh
  Body: {"refresh_token": "..."}
  """
  def refresh(conn, %{"refresh_token" => refresh_token}) do
    # Verify refresh token
    with {:ok, claims} <- Auth.verify_refresh_token(refresh_token),
         {:ok, session} <- Auth.verify_device_session(refresh_token) do
      user_id = claims["sub"]
      device_id = claims["device_id"]

      # Generate new tokens (rotate refresh token)
      {:ok, new_access_token} = Auth.generate_access_token(user_id, device_id)
      {:ok, new_refresh_token} = Auth.generate_refresh_token(user_id, device_id)

      # Delete old session and create new one
      Auth.delete_device_session(refresh_token)
      {:ok, _session} = Auth.create_device_session(device_id, new_refresh_token)

      json(conn, %{
        success: true,
        access_token: new_access_token,
        refresh_token: new_refresh_token,
        expires_in: 900
      })
    else
      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "refresh_token_expired"})

      {:error, _reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_refresh_token"})
    end
  end

  @doc """
  Logout (delete device session).
  DELETE /api/auth/logout
  Body: {"refresh_token": "..."}
  """
  def logout(conn, %{"refresh_token" => refresh_token}) do
    case Auth.delete_device_session(refresh_token) do
      {:ok, _} ->
        json(conn, %{success: true})

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_refresh_token"})
    end
  end

  ## Helpers

  defp normalize_phone(phone) do
    phone
    |> String.replace(~r/\D/, "")
    |> String.trim_leading("0")
  end

  defp hash_phone(phone) do
    :crypto.hash(:sha256, phone) |> Base.encode16(case: :lower)
  end
end
