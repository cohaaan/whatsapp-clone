defmodule Chat.Auth do
  @moduledoc """
  Authentication module handling JWT tokens and OTP verification.
  """

  require Logger

  @access_token_ttl 15 * 60  # 15 minutes
  @refresh_token_ttl 7 * 24 * 60 * 60  # 7 days

  ## JWT Token Generation

  @doc """
  Generate access token (short-lived, 15 minutes).
  """
  def generate_access_token(user_id, device_id) do
    claims = %{
      "sub" => user_id,
      "device_id" => device_id,
      "type" => "access",
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "exp" => DateTime.utc_now() |> DateTime.add(@access_token_ttl, :second) |> DateTime.to_unix()
    }

    sign_token(claims)
  end

  @doc """
  Generate refresh token (long-lived, 7 days).
  """
  def generate_refresh_token(user_id, device_id) do
    claims = %{
      "sub" => user_id,
      "device_id" => device_id,
      "type" => "refresh",
      "iat" => DateTime.utc_now() |> DateTime.to_unix(),
      "exp" => DateTime.utc_now() |> DateTime.add(@refresh_token_ttl, :second) |> DateTime.to_unix()
    }

    sign_token(claims)
  end

  @doc """
  Verify access token.
  """
  def verify_access_token(token) do
    with {:ok, claims} <- verify_token(token),
         :ok <- verify_token_type(claims, "access") do
      {:ok, claims}
    end
  end

  @doc """
  Verify refresh token.
  """
  def verify_refresh_token(token) do
    with {:ok, claims} <- verify_token(token),
         :ok <- verify_token_type(claims, "refresh") do
      {:ok, claims}
    end
  end

  defp sign_token(claims) do
    secret = get_jwt_secret()
    signer = Joken.Signer.create("HS256", secret)

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _claims} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_token(token) do
    secret = get_jwt_secret()
    signer = Joken.Signer.create("HS256", secret)

    case Joken.verify_and_validate(%{}, token, signer) do
      {:ok, claims} -> {:ok, claims}
      {:error, :exp} -> {:error, :expired}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_token_type(claims, expected_type) do
    case claims["type"] do
      ^expected_type -> :ok
      _ -> {:error, :invalid_token_type}
    end
  end

  defp get_jwt_secret do
    Application.get_env(:chat, Chat.Auth)[:jwt_secret] ||
      raise "JWT_SECRET not configured"
  end

  ## OTP Management

  @doc """
  Generate OTP code (6 digits).
  """
  def generate_otp do
    # Generate 6-digit code
    :rand.uniform(999_999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  @doc """
  Store OTP in ETS cache (5 minute expiry).
  """
  def store_otp(phone_number, otp) do
    table = :otp_cache

    # Create table if doesn't exist
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
    end

    # Store with timestamp
    expires_at = System.system_time(:second) + 300  # 5 minutes

    :ets.insert(table, {phone_number, otp, expires_at})
    :ok
  end

  @doc """
  Verify OTP code.
  """
  def verify_otp(phone_number, otp) do
    table = :otp_cache

    case :ets.lookup(table, phone_number) do
      [{^phone_number, stored_otp, expires_at}] ->
        now = System.system_time(:second)

        cond do
          now > expires_at ->
            :ets.delete(table, phone_number)
            {:error, :expired}

          stored_otp == otp ->
            :ets.delete(table, phone_number)
            :ok

          true ->
            {:error, :invalid_code}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Send OTP via SMS (Twilio).
  """
  def send_otp_sms(phone_number, otp) do
    # Check if Twilio is configured
    twilio_config = Application.get_env(:chat, :twilio)

    if twilio_config do
      send_via_twilio(phone_number, otp, twilio_config)
    else
      # Development mode: just log OTP
      Logger.info("OTP for #{phone_number}: #{otp}")
      {:ok, :dev_mode}
    end
  end

  defp send_via_twilio(phone_number, otp, config) do
    account_sid = config[:account_sid]
    auth_token = config[:auth_token]
    from_number = config[:from_number]

    url = "https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json"

    body = URI.encode_query(%{
      "To" => phone_number,
      "From" => from_number,
      "Body" => "Your verification code is: #{otp}. Valid for 5 minutes."
    })

    headers = [
      {"Authorization", "Basic " <> Base.encode64("#{account_sid}:#{auth_token}")},
      {"Content-Type", "application/x-www-form-urlencoded"}
    ]

    case :httpc.request(:post, {String.to_charlist(url), headers, 'application/x-www-form-urlencoded', String.to_charlist(body)}, [], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        {:ok, :sent}

      {:ok, {{_, 201, _}, _, _}} ->
        {:ok, :sent}

      {:ok, {{_, status, _}, _, response}} ->
        Logger.error("Twilio SMS failed: #{status} - #{response}")
        {:error, :send_failed}

      {:error, reason} ->
        Logger.error("Twilio SMS error: #{inspect(reason)}")
        {:error, :send_failed}
    end
  end

  ## Device Session Management

  @doc """
  Create device session with refresh token.
  """
  def create_device_session(device_id, refresh_token) do
    alias Chat.Repo
    alias Chat.Accounts.DeviceSession

    # Hash refresh token for storage
    token_hash = Bcrypt.hash_pwd_salt(refresh_token)

    attrs = %{
      device_id: device_id,
      refresh_token_hash: token_hash,
      expires_at: DateTime.utc_now() |> DateTime.add(@refresh_token_ttl, :second)
    }

    %DeviceSession{}
    |> DeviceSession.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Verify refresh token and return device session.
  """
  def verify_device_session(refresh_token) do
    alias Chat.Repo
    alias Chat.Accounts.DeviceSession
    import Ecto.Query

    # Find all non-expired sessions
    sessions = Repo.all(
      from s in DeviceSession,
      where: s.expires_at > ^DateTime.utc_now()
    )

    # Check each session's hash
    Enum.find_value(sessions, {:error, :invalid_token}, fn session ->
      if Bcrypt.verify_pass(refresh_token, session.refresh_token_hash) do
        # Update last_used_at
        session
        |> DeviceSession.touch_last_used_changeset()
        |> Repo.update()

        {:ok, session}
      else
        false
      end
    end)
  end

  @doc """
  Delete device session (logout).
  """
  def delete_device_session(refresh_token) do
    case verify_device_session(refresh_token) do
      {:ok, session} -> Chat.Repo.delete(session)
      error -> error
    end
  end
end
