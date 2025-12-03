defmodule ChatWeb.ConversationController do
  use ChatWeb, :controller

  alias Chat.Messaging

  @doc """
  List all conversations for current user.
  GET /api/conversations
  """
  def index(conn, _params) do
    user_id = conn.assigns.user_id

    conversations = Messaging.list_user_conversations(user_id)

    json(conn, %{
      conversations: Enum.map(conversations, &serialize_conversation/1)
    })
  end

  @doc """
  Create a new conversation.
  POST /api/conversations
  Body: {"type": "dm", "member_user_ids": ["user1", "user2"]} or
        {"type": "group", "name": "Group Name", "member_user_ids": [...]}
  """
  def create(conn, %{"type" => type, "member_user_ids" => member_ids} = params) do
    user_id = conn.assigns.user_id

    attrs = %{
      type: type,
      name: params["name"],
      created_by: user_id,
      member_user_ids: [user_id | member_ids] |> Enum.uniq()
    }

    case Messaging.create_conversation(attrs) do
      {:ok, conversation} ->
        conn
        |> put_status(:created)
        |> json(%{
          success: true,
          conversation: serialize_conversation(conversation)
        })

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "create_failed", details: translate_errors(changeset)})
    end
  end

  @doc """
  Get conversation details.
  GET /api/conversations/:id
  """
  def show(conn, %{"id" => conversation_id}) do
    user_id = conn.assigns.user_id

    # Verify membership
    if Messaging.conversation_member?(conversation_id, user_id) do
      case Messaging.get_conversation(conversation_id) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "conversation_not_found"})

        conversation ->
          json(conn, serialize_conversation(conversation))
      end
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "not_a_member"})
    end
  end

  @doc """
  Get messages for a conversation.
  GET /api/conversations/:id/messages?since=<timestamp>&limit=50
  """
  def messages(conn, %{"id" => conversation_id} = params) do
    user_id = conn.assigns.user_id

    if Messaging.conversation_member?(conversation_id, user_id) do
      since =
        case params["since"] do
          nil -> nil
          timestamp_str -> parse_datetime(timestamp_str)
        end

      limit = String.to_integer(params["limit"] || "50")

      messages = Messaging.list_conversation_messages(conversation_id, since, limit)

      json(conn, %{
        messages: Enum.map(messages, &serialize_message/1)
      })
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "not_a_member"})
    end
  end

  defp serialize_conversation(conversation) do
    %{
      id: conversation.id,
      type: conversation.type,
      name: conversation.name,
      created_at: conversation.inserted_at
    }
  end

  defp serialize_message(message) do
    %{
      id: message.id,
      conversation_id: message.conversation_id,
      sender_device_id: message.sender_device_id,
      message_type: message.message_type,
      content_type: message.content_type,
      client_timestamp: message.client_timestamp,
      inserted_at: message.inserted_at
    }
  end

  defp parse_datetime(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
