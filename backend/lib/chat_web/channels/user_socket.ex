defmodule ChatWeb.UserSocket do
  use Phoenix.Socket
  require Logger

  ## Channels
  channel "conversation:*", ChatWeb.RoomChannel
  channel "user:*", ChatWeb.UserChannel

  # Socket params are passed from the client and can be used to verify
  # and authenticate a user. After verification, assign user_id and device_id
  # to the socket for later use in channels.
  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_token(token) do
      {:ok, user_id, device_id} ->
        # Verify device is still active
        case Chat.Accounts.get_device(device_id) do
          nil ->
            Logger.warning("Device not found: #{device_id}")
            :error

          device ->
            # Update last_seen_at
            Chat.Accounts.update_device_last_seen(device)

            socket =
              socket
              |> assign(:user_id, user_id)
              |> assign(:device_id, device_id)
              |> assign(:device, device)

            {:ok, socket}
        end

      {:error, reason} ->
        Logger.warning("Socket authentication failed: #{inspect(reason)}")
        :error
    end
  end

  # Reject connection if no token provided
  def connect(_params, _socket, _connect_info) do
    Logger.warning("Socket connection attempted without token")
    :error
  end

  # Socket id for debugging and termination
  # Format: "user_socket:#{user_id}:#{device_id}"
  @impl true
  def id(socket) do
    "user_socket:#{socket.assigns.user_id}:#{socket.assigns.device_id}"
  end

  # Verify JWT token and extract claims
  defp verify_token(token) do
    with {:ok, %{"sub" => user_id, "device_id" => device_id, "type" => "access"} = _claims} <-
           Chat.Auth.verify_access_token(token) do
      {:ok, user_id, device_id}
    else
      {:error, :expired} ->
        {:error, :token_expired}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_token}
    end
  end
end
