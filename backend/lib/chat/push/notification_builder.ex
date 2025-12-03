defmodule Chat.Push.NotificationBuilder do
  @moduledoc """
  Builds E2E-compliant push notifications.

  CRITICAL: Push payload must NOT contain message content (server is zero-knowledge).
  """

  alias Chat.Messaging.{Message, MessageEnvelope}
  alias Chat.Accounts.Device

  @doc """
  Build APNs notification.

  Payload contains NO message content, only metadata for client to fetch and decrypt.
  """
  def build_apns_notification(envelope, device) do
    # Load message to get sender info
    message = Chat.Repo.get!(Message, envelope.message_id)
    sender = get_sender_info(message.sender_device_id)

    notification = %{
      "type" => "new_message",
      "conversation_id" => message.conversation_id,
      "sender_id" => sender.user_id,
      "sender_name" => sender.name || "Unknown",
      "message_id" => message.id
    }

    Pigeon.APNS.Notification.new(
      notification,
      device.push_token,
      "chat.app"
    )
    |> Pigeon.APNS.Notification.put_alert(%{
      "title" => sender.name || "New Message",
      "body" => "You have a new message"
    })
    |> Pigeon.APNS.Notification.put_badge(1)
    |> Pigeon.APNS.Notification.put_sound("default")
    |> Pigeon.APNS.Notification.put_category("MESSAGE")
    |> Pigeon.APNS.Notification.put_mutable_content(1)
  end

  @doc """
  Build FCM notification.
  """
  def build_fcm_notification(envelope, device) do
    message = Chat.Repo.get!(Message, envelope.message_id)
    sender = get_sender_info(message.sender_device_id)

    notification_data = %{
      "type" => "new_message",
      "conversation_id" => message.conversation_id,
      "sender_id" => sender.user_id,
      "sender_name" => sender.name || "Unknown",
      "message_id" => message.id
    }

    Pigeon.FCM.Notification.new(
      device.push_token,
      notification_data
    )
    |> Pigeon.FCM.Notification.put_notification(%{
      "title" => sender.name || "New Message",
      "body" => "You have a new message"
    })
    |> Pigeon.FCM.Notification.put_priority(:high)
  end

  defp get_sender_info(sender_device_id) do
    # In production, cache this in ETS for performance
    device = Chat.Repo.get(Chat.Accounts.Device, sender_device_id)

    if device do
      user = Chat.Repo.get(Chat.Accounts.User, device.user_id)
      %{user_id: device.user_id, name: user.name || "Unknown"}
    else
      %{user_id: nil, name: "Unknown"}
    end
  end
end
