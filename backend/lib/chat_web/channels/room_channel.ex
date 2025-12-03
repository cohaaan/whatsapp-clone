defmodule ChatWeb.RoomChannel do
  use ChatWeb, :channel
  require Logger

  alias Chat.{Messaging, Presence}
  alias ChatWeb.Presence, as: PresenceTracker

  @impl true
  def join("conversation:" <> conversation_id, _payload, socket) do
    # Verify user is a member of this conversation
    case Messaging.conversation_member?(conversation_id, socket.assigns.user_id) do
      true ->
        socket = assign(socket, :conversation_id, conversation_id)

        # Track presence
        send(self(), :after_join)

        {:ok, socket}

      false ->
        Logger.warning(
          "Unauthorized join attempt: user=#{socket.assigns.user_id} conv=#{conversation_id}"
        )

        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    conversation_id = socket.assigns.conversation_id
    device_id = socket.assigns.device_id
    user_id = socket.assigns.user_id

    # Track in Presence
    {:ok, _} =
      PresenceTracker.track(socket, device_id, %{
        device_id: device_id,
        user_id: user_id,
        online_at: System.system_time(:second)
      })

    # Push presence state to joining device
    push(socket, "presence_state", PresenceTracker.list(socket))

    # Drain offline queue for this device
    Task.start(fn ->
      Messaging.drain_offline_queue(device_id, conversation_id)
    end)

    {:noreply, socket}
  end

  # Handle incoming message
  @impl true
  def handle_in("msg:send", payload, socket) do
    %{
      "idempotency_key" => idempotency_key,
      "envelope" => envelope,
      "content_type" => content_type,
      "client_timestamp" => client_timestamp
    } = payload

    conversation_id = socket.assigns.conversation_id
    sender_device_id = socket.assigns.device_id

    # Check rate limit
    case Chat.RateLimiter.check_message_rate(socket.assigns.user_id, sender_device_id) do
      {:allow, _} ->
        # Send message (this handles idempotency, persistence, broadcast, and queuing)
        case Messaging.send_message(
               conversation_id,
               sender_device_id,
               envelope,
               idempotency_key,
               content_type,
               client_timestamp
             ) do
          {:ok, message} ->
            # Ack to sender
            {:reply, {:ok, %{message_id: message.id}}, socket}

          {:error, :duplicate} ->
            # Idempotency hit - find existing message
            case Messaging.get_message_by_idempotency_key(idempotency_key) do
              nil ->
                {:reply, {:error, %{reason: "duplicate_but_not_found"}}, socket}

              message ->
                {:reply, {:ok, %{message_id: message.id, duplicate: true}}, socket}
            end

          {:error, reason} ->
            Logger.error("Failed to send message: #{inspect(reason)}")
            {:reply, {:error, %{reason: "send_failed"}}, socket}
        end

      {:deny, _limit} ->
        {:reply, {:error, %{reason: "rate_limited"}}, socket}
    end
  end

  # Handle message acknowledgment (delivered/read status)
  @impl true
  def handle_in("msg:ack", %{"message_id" => message_id, "status" => status}, socket)
      when status in ["delivered", "read"] do
    device_id = socket.assigns.device_id

    case Messaging.update_envelope_status(message_id, device_id, status) do
      {:ok, _envelope} ->
        # Broadcast ack to sender (so they see delivery/read receipts)
        broadcast_from(socket, "msg:ack", %{
          message_id: message_id,
          device_id: device_id,
          status: status
        })

        {:reply, :ok, socket}

      {:error, reason} ->
        Logger.warning("Failed to update envelope status: #{inspect(reason)}")
        {:reply, {:error, %{reason: "ack_failed"}}, socket}
    end
  end

  # Handle typing indicator (ephemeral, no persistence)
  @impl true
  def handle_in("typing", _payload, socket) do
    broadcast_from(socket, "typing", %{
      user_id: socket.assigns.user_id,
      device_id: socket.assigns.device_id
    })

    {:noreply, socket}
  end

  # Handle stop typing
  @impl true
  def handle_in("typing:stop", _payload, socket) do
    broadcast_from(socket, "typing:stop", %{
      user_id: socket.assigns.user_id,
      device_id: socket.assigns.device_id
    })

    {:noreply, socket}
  end

  # Intercept outgoing broadcasts to add metadata
  @impl true
  def handle_out("msg:new", payload, socket) do
    # Only push if this message is for this device
    device_id = socket.assigns.device_id

    if device_id in payload.recipient_device_ids do
      push(socket, "msg:new", payload)
    end

    {:noreply, socket}
  end

  def handle_out(event, payload, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end
end
