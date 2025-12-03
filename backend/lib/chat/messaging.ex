defmodule Chat.Messaging do
  @moduledoc """
  The Messaging context handles all message-related operations including:
  - Sending messages (pairwise and sender_key)
  - Message delivery tracking
  - Offline queue management
  - Conversation membership
  """

  import Ecto.Query
  require Logger

  alias Chat.Repo
  alias Chat.Cache.Idempotency
  alias Chat.Messaging.{Message, MessagePayload, MessageEnvelope, Conversation}
  alias Ecto.Multi

  @doc """
  Send a message with full transaction safety.

  Steps:
  1. Check idempotency (L1/L2)
  2. Insert message
  3. Insert payload(s)
  4. Insert envelopes for each recipient device
  5. Broadcast to online devices
  6. Queue for offline devices

  Returns {:ok, message} or {:error, reason}
  """
  def send_message(
        conversation_id,
        sender_device_id,
        envelope_data,
        idempotency_key,
        content_type \\ 0,
        client_timestamp
      ) do
    message_id = Ecto.UUID.generate()

    # Get sender user_id for idempotency check
    sender_user_id = get_user_id_from_device(sender_device_id)

    Multi.new()
    |> Multi.run(:idempotency, fn _repo, _changes ->
      case Idempotency.check_and_insert(idempotency_key, sender_user_id, message_id) do
        {:ok, ^message_id} -> {:ok, :not_duplicate}
        {:error, :duplicate} -> {:error, :duplicate}
      end
    end)
    |> Multi.run(:message, fn _repo, _changes ->
      create_message(message_id, conversation_id, sender_device_id, envelope_data, content_type, client_timestamp)
    end)
    |> Multi.run(:payload, fn _repo, %{message: message} ->
      create_message_payload(message, envelope_data)
    end)
    |> Multi.run(:envelopes, fn _repo, %{message: message} ->
      create_message_envelopes(message, envelope_data)
    end)
    |> Multi.run(:broadcast, fn _repo, %{message: message, envelopes: envelopes} ->
      broadcast_to_online(message, envelopes)
      {:ok, :broadcasted}
    end)
    |> Multi.run(:queue_offline, fn _repo, %{envelopes: envelopes} ->
      queue_offline_deliveries(envelopes)
      {:ok, :queued}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        {:ok, message}

      {:error, :idempotency, :duplicate, _} ->
        {:error, :duplicate}

      {:error, step, reason, _} ->
        Logger.error("Message send failed at #{step}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Update message envelope status (delivered/read).
  """
  def update_envelope_status(message_id, device_id, status) when status in ["delivered", "read"] do
    envelope =
      Repo.get_by(MessageEnvelope,
        message_id: message_id,
        recipient_device_id: device_id
      )

    case envelope do
      nil ->
        {:error, :not_found}

      envelope ->
        changes =
          case status do
            "delivered" -> %{status: "delivered", delivered_at: DateTime.utc_now()}
            "read" -> %{status: "read", read_at: DateTime.utc_now()}
          end

        envelope
        |> MessageEnvelope.changeset(changes)
        |> Repo.update()
    end
  end

  @doc """
  Drain offline queue for a device when it comes online.
  """
  def drain_offline_queue(device_id, conversation_id) do
    # Get pending deliveries for this device in this conversation
    pending =
      from(pd in "pending_deliveries",
        join: e in MessageEnvelope,
        on: pd.envelope_id == e.id,
        join: m in Message,
        on: e.message_id == m.id,
        where: pd.device_id == ^device_id and m.conversation_id == ^conversation_id,
        select: %{
          pending_delivery_id: pd.id,
          envelope: e,
          message: m
        },
        order_by: [asc: pd.inserted_at],
        limit: 100
      )
      |> Repo.all()

    if length(pending) > 0 do
      Logger.info("Draining #{length(pending)} offline messages for device #{device_id}")

      Enum.each(pending, fn %{envelope: envelope, message: message, pending_delivery_id: pd_id} ->
        # Broadcast via PubSub to the connected device's channel
        ChatWeb.Endpoint.broadcast(
          "conversation:#{conversation_id}",
          "msg:new",
          %{
            message_id: message.id,
            sender_device_id: message.sender_device_id,
            envelope: serialize_envelope(envelope),
            content_type: message.content_type,
            client_timestamp: message.client_timestamp,
            recipient_device_ids: [device_id]
          }
        )

        # Remove from pending_deliveries
        Repo.delete_all(from pd in "pending_deliveries", where: pd.id == ^pd_id)
      end)
    end

    :ok
  end

  @doc """
  Check if user is a member of conversation.
  """
  def conversation_member?(conversation_id, user_id) do
    query =
      from cm in "conversation_members",
        where: cm.conversation_id == ^conversation_id and cm.user_id == ^user_id and is_nil(cm.left_at),
        select: count()

    Repo.one(query) > 0
  end

  @doc """
  Get message by idempotency key (for duplicate detection).
  """
  def get_message_by_idempotency_key(idempotency_key) do
    ik = Repo.get_by(Chat.Messaging.IdempotencyKey, key: idempotency_key)

    case ik do
      nil -> nil
      %{message_id: message_id} -> Repo.get(Message, message_id)
    end
  end

  ## Private Functions

  defp get_user_id_from_device(device_id) do
    device = Repo.get!(Chat.Accounts.Device, device_id)
    device.user_id
  end

  defp create_message(message_id, conversation_id, sender_device_id, envelope_data, content_type, client_timestamp) do
    message_type = envelope_data["message_type"] || "pairwise"

    attrs = %{
      id: message_id,
      conversation_id: conversation_id,
      sender_device_id: sender_device_id,
      message_type: message_type,
      content_type: content_type,
      client_timestamp: parse_timestamp(client_timestamp)
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  defp create_message_payload(message, envelope_data) do
    case message.message_type do
      "sender_key" ->
        # One payload for all recipients (Sender Key encrypted)
        payload_attrs = %{
          id: Ecto.UUID.generate(),
          message_id: message.id,
          recipient_device_id: nil,
          ciphertext: envelope_data["ciphertext"]
        }

        %MessagePayload{}
        |> MessagePayload.changeset(payload_attrs)
        |> Repo.insert()

      "pairwise" ->
        # Multiple payloads (one per recipient)
        # For DMs this is typically 1-2 payloads
        recipient_payloads = envelope_data["recipient_payloads"] || []

        results =
          Enum.map(recipient_payloads, fn rp ->
            payload_attrs = %{
              id: Ecto.UUID.generate(),
              message_id: message.id,
              recipient_device_id: rp["device_id"],
              ciphertext: rp["ciphertext"]
            }

            %MessagePayload{}
            |> MessagePayload.changeset(payload_attrs)
            |> Repo.insert!()
          end)

        {:ok, results}
    end
  end

  defp create_message_envelopes(message, envelope_data) do
    # Get all recipient devices for this conversation
    recipient_devices = get_conversation_recipient_devices(message.conversation_id, message.sender_device_id)

    envelopes =
      Enum.map(recipient_devices, fn device_id ->
        # Find the appropriate key_header for this device
        key_header = find_key_header_for_device(envelope_data, device_id)

        envelope_attrs = %{
          id: Ecto.UUID.generate(),
          message_id: message.id,
          recipient_device_id: device_id,
          key_header: key_header,
          ephemeral_key: envelope_data["ephemeral_key"],
          status: "pending"
        }

        %MessageEnvelope{}
        |> MessageEnvelope.changeset(envelope_attrs)
        |> Repo.insert!()
      end)

    {:ok, envelopes}
  end

  defp get_conversation_recipient_devices(conversation_id, sender_device_id) do
    # Get all devices of conversation members (excluding sender's device)
    query =
      from d in Chat.Accounts.Device,
        join: cm in "conversation_members",
        on: d.user_id == cm.user_id,
        where: cm.conversation_id == ^conversation_id and is_nil(cm.left_at) and d.id != ^sender_device_id,
        select: d.id

    Repo.all(query)
  end

  defp find_key_header_for_device(envelope_data, device_id) do
    # Key headers are device-specific encryption metadata
    headers = envelope_data["key_headers"] || []

    case Enum.find(headers, fn h -> h["device_id"] == device_id end) do
      nil ->
        # For sender_key, header might be shared
        envelope_data["key_header"]

      header ->
        header["header"]
    end
  end

  defp broadcast_to_online(message, envelopes) do
    # Get online device IDs from Presence
    online_devices = get_online_devices_in_conversation(message.conversation_id)

    # Filter envelopes for online recipients
    online_envelopes = Enum.filter(envelopes, fn e -> e.recipient_device_id in online_devices end)

    if length(online_envelopes) > 0 do
      recipient_device_ids = Enum.map(online_envelopes, & &1.recipient_device_id)

      ChatWeb.Endpoint.broadcast(
        "conversation:#{message.conversation_id}",
        "msg:new",
        %{
          message_id: message.id,
          sender_device_id: message.sender_device_id,
          content_type: message.content_type,
          client_timestamp: message.client_timestamp,
          recipient_device_ids: recipient_device_ids
        }
      )
    end

    {:ok, online_envelopes}
  end

  defp queue_offline_deliveries(envelopes) do
    online_devices = get_all_online_devices()

    offline_envelopes =
      Enum.filter(envelopes, fn e -> e.recipient_device_id not in online_devices end)

    if length(offline_envelopes) > 0 do
      # Insert into pending_deliveries
      entries =
        Enum.map(offline_envelopes, fn envelope ->
          %{
            id: Ecto.UUID.generate(),
            envelope_id: envelope.id,
            device_id: envelope.recipient_device_id,
            inserted_at: DateTime.utc_now(),
            updated_at: DateTime.utc_now()
          }
        end)

      Repo.insert_all("pending_deliveries", entries, on_conflict: :nothing)

      Logger.debug("Queued #{length(offline_envelopes)} messages for offline delivery")
    end

    :ok
  end

  defp get_online_devices_in_conversation(conversation_id) do
    # Query Presence for this conversation's channel
    presence_list = ChatWeb.Presence.list("conversation:#{conversation_id}")

    presence_list
    |> Map.values()
    |> Enum.flat_map(fn %{metas: metas} ->
      Enum.map(metas, fn meta -> meta.device_id end)
    end)
  end

  defp get_all_online_devices do
    # Get all conversations and aggregate online devices
    # This is a simplification; in production, use a global presence tracker
    # or cache online device IDs in ETS
    []
  end

  defp serialize_envelope(envelope) do
    %{
      id: envelope.id,
      key_header: envelope.key_header,
      ephemeral_key: envelope.ephemeral_key
    }
  end

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()

  ## Conversation Management

  @doc """
  List all conversations for a user.
  """
  def list_user_conversations(user_id) do
    query =
      from c in Conversation,
        join: cm in "conversation_members",
        on: cm.conversation_id == c.id,
        where: cm.user_id == ^user_id and is_nil(cm.left_at),
        order_by: [desc: c.inserted_at]

    Repo.all(query)
  end

  @doc """
  Get conversation by ID.
  """
  def get_conversation(conversation_id) do
    Repo.get(Conversation, conversation_id)
  end

  @doc """
  Create a new conversation with members.
  """
  def create_conversation(attrs) do
    Multi.new()
    |> Multi.insert(:conversation, fn _ ->
      %Conversation{}
      |> Conversation.changeset(attrs)
    end)
    |> Multi.run(:members, fn _repo, %{conversation: conversation} ->
      insert_conversation_members(conversation.id, attrs[:member_user_ids])
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{conversation: conversation}} -> {:ok, conversation}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp insert_conversation_members(conversation_id, user_ids) do
    entries =
      Enum.map(user_ids, fn user_id ->
        %{
          conversation_id: conversation_id,
          user_id: user_id,
          role: "member",
          joined_at: DateTime.utc_now()
        }
      end)

    {count, _} = Repo.insert_all("conversation_members", entries)
    {:ok, count}
  end

  @doc """
  List messages for a conversation.
  """
  def list_conversation_messages(conversation_id, since \\ nil, limit \\ 50) do
    query =
      from m in Message,
        where: m.conversation_id == ^conversation_id,
        order_by: [desc: m.inserted_at],
        limit: ^limit

    query =
      if since do
        from m in query, where: m.inserted_at > ^since
      else
        query
      end

    Repo.all(query)
  end
end
