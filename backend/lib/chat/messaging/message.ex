defmodule Chat.Messaging.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "messages" do
    field :message_type, :string
    field :content_type, :integer, default: 0
    field :client_timestamp, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :conversation, Chat.Messaging.Conversation, type: :binary_id, define_field: false
    field :conversation_id, :binary_id

    belongs_to :sender_device, Chat.Accounts.Device, type: :binary_id, define_field: false
    field :sender_device_id, :binary_id

    has_many :envelopes, Chat.Messaging.MessageEnvelope
    has_many :payloads, Chat.Messaging.MessagePayload
  end

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:id, :conversation_id, :sender_device_id, :message_type, :content_type, :client_timestamp])
    |> validate_required([:id, :conversation_id, :sender_device_id, :message_type, :content_type, :client_timestamp])
    |> validate_inclusion(:message_type, ["pairwise", "sender_key"])
    |> validate_number(:content_type, greater_than_or_equal_to: 0)
    |> put_inserted_at()
  end

  defp put_inserted_at(changeset) do
    put_change(changeset, :inserted_at, DateTime.utc_now())
  end
end
