defmodule ChatWeb.MessageController do
  use ChatWeb, :controller

  alias Chat.Messaging

  @doc """
  Send a message (REST fallback, prefer WebSocket).
  POST /api/messages
  Body: {
    "conversation_id": "...",
    "envelope": {...},
    "idempotency_key": "...",
    "content_type": 0,
    "client_timestamp": "2025-01-01T00:00:00Z"
  }
  """
  def create(conn, params) do
    sender_device_id = conn.assigns.device_id

    conversation_id = params["conversation_id"]
    envelope = params["envelope"]
    idempotency_key = params["idempotency_key"]
    content_type = params["content_type"] || 0
    client_timestamp = params["client_timestamp"]

    # Verify membership
    user_id = conn.assigns.user_id

    if Messaging.conversation_member?(conversation_id, user_id) do
      case Messaging.send_message(
             conversation_id,
             sender_device_id,
             envelope,
             idempotency_key,
             content_type,
             client_timestamp
           ) do
        {:ok, message} ->
          conn
          |> put_status(:created)
          |> json(%{
            success: true,
            message_id: message.id
          })

        {:error, :duplicate} ->
          # Idempotency hit - return success with existing message ID
          case Messaging.get_message_by_idempotency_key(idempotency_key) do
            nil ->
              conn
              |> put_status(:conflict)
              |> json(%{error: "duplicate_but_not_found"})

            message ->
              json(conn, %{
                success: true,
                message_id: message.id,
                duplicate: true
              })
          end

        {:error, reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "send_failed", reason: inspect(reason)})
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "not_a_member"})
    end
  end
end
