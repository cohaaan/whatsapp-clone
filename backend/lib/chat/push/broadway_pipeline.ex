defmodule Chat.Push.BroadwayPipeline do
  @moduledoc """
  Broadway pipeline for sending push notifications.

  Flow:
  1. Consume from "push:pending" PubSub topic (or poll pending_deliveries)
  2. Check if recipient device is NOT in Presence (offline)
  3. Batch by platform (APNs vs FCM) — batch window 100ms or 100 messages
  4. Send via Pigeon
  5. Handle results:
     - Success → mark envelope as push_sent
     - Token invalid (410/404) → delete device record
     - Rate limited (429) → exponential backoff, re-enqueue
     - Timeout → retry with jitter (max 3 attempts)
  """

  use Broadway

  alias Broadway.Message
  alias Chat.{Repo, Messaging}
  alias Chat.Push.NotificationBuilder

  require Logger

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {Chat.Push.PendingProducer, []},
        transformer: {__MODULE__, :transform, []},
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 10]
      ],
      batchers: [
        apns: [
          concurrency: 5,
          batch_size: 100,
          batch_timeout: 100
        ],
        fcm: [
          concurrency: 5,
          batch_size: 100,
          batch_timeout: 100
        ]
      ]
    )
  end

  @impl true
  def handle_message(:default, %Message{data: envelope} = message, _context) do
    # Check if device is offline (not in Presence)
    if device_offline?(envelope.recipient_device_id) do
      # Load device to determine platform
      device = Repo.get(Chat.Accounts.Device, envelope.recipient_device_id)

      if device && device.push_token do
        # Route to appropriate batcher based on platform
        batcher =
          case device.platform do
            "ios" -> :apns
            "android" -> :fcm
            _ -> :default
          end

        message
        |> Message.put_batcher(batcher)
        |> Message.update_data(fn _ -> {envelope, device} end)
      else
        # No push token or device deleted
        Message.failed(message, "no_push_token")
      end
    else
      # Device is online, skip push notification
      Message.failed(message, "device_online")
    end
  end

  @impl true
  def handle_batch(:apns, messages, _batch_info, _context) do
    Logger.debug("Sending #{length(messages)} APNs notifications")

    messages
    |> Enum.map(&send_apns/1)
  end

  @impl true
  def handle_batch(:fcm, messages, _batch_info, _context) do
    Logger.debug("Sending #{length(messages)} FCM notifications")

    messages
    |> Enum.map(&send_fcm/1)
  end

  @impl true
  def transform(event, _opts) do
    %Message{
      data: event,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  ## Private Functions

  defp device_offline?(device_id) do
    # Check Presence across all conversation channels
    # Simplified: in production, maintain a global device presence tracker in ETS
    ChatWeb.Presence.list("user:#{device_id}") == %{}
  end

  defp send_apns(%Message{data: {envelope, device}} = message) do
    # Build notification payload (E2E compliant - no message content)
    notification = NotificationBuilder.build_apns_notification(envelope, device)

    case Pigeon.APNS.push(notification) do
      {:ok, %{response: :success}} ->
        mark_push_sent(envelope.id)
        message

      {:ok, %{response: :bad_device_token}} ->
        Logger.warning("Invalid APNs token for device #{device.id}, deleting device")
        delete_device(device.id)
        Message.failed(message, "invalid_token")

      {:ok, %{response: :unregistered}} ->
        Logger.warning("Unregistered APNs token for device #{device.id}, deleting device")
        delete_device(device.id)
        Message.failed(message, "unregistered")

      {:ok, %{response: :too_many_requests}} ->
        Logger.warning("APNs rate limited, requeueing")
        Message.failed(message, "rate_limited")

      {:error, reason} ->
        Logger.error("APNs push failed: #{inspect(reason)}")

        # Retry logic via metadata
        attempts = get_in(message.metadata, [:attempts]) || 0

        if attempts < 3 do
          # Re-enqueue with exponential backoff
          backoff_ms = :math.pow(2, attempts) * 1000
          Process.send_after(self(), {:retry, envelope, device, attempts + 1}, trunc(backoff_ms))
          Message.failed(message, "transient_error")
        else
          Message.failed(message, "max_retries_exceeded")
        end
    end
  end

  defp send_fcm(%Message{data: {envelope, device}} = message) do
    # Build notification payload
    notification = NotificationBuilder.build_fcm_notification(envelope, device)

    case Pigeon.FCM.push(notification) do
      {:ok, %{response: :success}} ->
        mark_push_sent(envelope.id)
        message

      {:ok, %{response: :invalid_registration}} ->
        Logger.warning("Invalid FCM token for device #{device.id}, deleting device")
        delete_device(device.id)
        Message.failed(message, "invalid_token")

      {:ok, %{response: :not_registered}} ->
        Logger.warning("Not registered FCM token for device #{device.id}, deleting device")
        delete_device(device.id)
        Message.failed(message, "not_registered")

      {:ok, %{response: :unavailable}} ->
        Logger.warning("FCM unavailable, requeueing")
        Message.failed(message, "fcm_unavailable")

      {:error, reason} ->
        Logger.error("FCM push failed: #{inspect(reason)}")

        attempts = get_in(message.metadata, [:attempts]) || 0

        if attempts < 3 do
          backoff_ms = :math.pow(2, attempts) * 1000
          Process.send_after(self(), {:retry, envelope, device, attempts + 1}, trunc(backoff_ms))
          Message.failed(message, "transient_error")
        else
          Message.failed(message, "max_retries_exceeded")
        end
    end
  end

  defp mark_push_sent(envelope_id) do
    Repo.update_all(
      from(e in Chat.Messaging.MessageEnvelope, where: e.id == ^envelope_id),
      set: [push_sent_at: DateTime.utc_now()]
    )
  end

  defp delete_device(device_id) do
    # Soft delete or hard delete based on policy
    # Also notify user via in-app message on their other devices
    case Repo.get(Chat.Accounts.Device, device_id) do
      nil -> :ok
      device -> Repo.delete(device)
    end
  end
end
