defmodule ChatWeb.DeviceController do
  use ChatWeb, :controller

  alias Chat.{Accounts, Encryption, RateLimiter}

  @doc """
  Get device info.
  GET /api/devices/:id
  """
  def show(conn, %{"id" => device_id}) do
    # Verify user owns this device
    current_device_id = conn.assigns.device_id

    if device_id == current_device_id do
      case Accounts.get_device(device_id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "device_not_found"})

        device ->
          json(conn, %{
            id: device.id,
            platform: device.platform,
            device_name: device.device_name,
            last_seen_at: device.last_seen_at,
            created_at: device.inserted_at
          })
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
    end
  end

  @doc """
  Update device (e.g., push token).
  PATCH /api/devices/:id
  Body: {"push_token": "..."}
  """
  def update(conn, %{"id" => device_id, "push_token" => push_token}) do
    current_device_id = conn.assigns.device_id

    if device_id == current_device_id do
      case Accounts.get_device(device_id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "device_not_found"})

        device ->
          case Accounts.update_device_push_token(device, push_token) do
            {:ok, updated_device} ->
              json(conn, %{
                success: true,
                device: %{
                  id: updated_device.id,
                  push_token: updated_device.push_token
                }
              })

            {:error, changeset} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "update_failed", details: translate_errors(changeset)})
          end
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
    end
  end

  @doc """
  Upload prekeys (for Signal Protocol).
  POST /api/devices/:id/prekeys
  Body: {
    "identity_public_key": "...",
    "signed_prekey": {"key_id": 1, "public_key": "...", "signature": "..."},
    "one_time_prekeys": [{"key_id": 1, "public_key": "..."}, ...]
  }
  """
  def upload_prekeys(conn, %{"id" => device_id} = params) do
    user_id = conn.assigns.user_id
    current_device_id = conn.assigns.device_id

    # Rate limiting
    case RateLimiter.check_prekey_upload_rate(user_id) do
      {:allow, _} ->
        if device_id == current_device_id do
          with {:ok, _} <- Encryption.store_identity_key(device_id, params["identity_public_key"]),
               {:ok, _} <- Encryption.store_signed_prekey(device_id, params["signed_prekey"]),
               {:ok, count} <- Encryption.store_one_time_prekeys(device_id, params["one_time_prekeys"]) do
            json(conn, %{
              success: true,
              prekeys_uploaded: count
            })
          else
            {:error, reason} ->
              conn
              |> put_status(:bad_request)
              |> json(%{error: "upload_failed", reason: inspect(reason)})
          end
        else
          conn
          |> put_status(:forbidden)
          |> json(%{error: "forbidden"})
        end

      {:deny, _limit} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "rate_limit_exceeded"})
    end
  end

  @doc """
  Get prekey count (for client to know when to upload more).
  GET /api/devices/:id/prekey_count
  """
  def prekey_count(conn, %{"id" => device_id}) do
    current_device_id = conn.assigns.device_id

    if device_id == current_device_id do
      count = Encryption.count_available_prekeys(device_id)

      json(conn, %{
        device_id: device_id,
        available_prekeys: count
      })
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
    end
  end

  @doc """
  Get prekey bundle for initiating session (called by another user).
  GET /api/devices/:device_id/prekey_bundle
  """
  def prekey_bundle(conn, %{"id" => target_device_id}) do
    case Encryption.get_prekey_bundle(target_device_id) do
      {:ok, bundle} ->
        json(conn, bundle)

      {:error, :no_prekeys_available} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "no_prekeys_available"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
