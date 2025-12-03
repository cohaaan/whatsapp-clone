defmodule Chat.Messaging.MessageEnvelope do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "message_envelopes" do
    field :ephemeral_key, :binary
    field :key_header, :binary
    field :status, :string, default: "pending"
    field :delivered_at, :utc_datetime_usec
    field :read_at, :utc_datetime_usec
    field :push_sent_at, :utc_datetime_usec

    belongs_to :message, Chat.Messaging.Message, type: :binary_id, define_field: false
    field :message_id, :binary_id

    belongs_to :recipient_device, Chat.Accounts.Device, type: :binary_id, define_field: false
    field :recipient_device_id, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(envelope, attrs) do
    envelope
    |> cast(attrs, [
      :id,
      :message_id,
      :recipient_device_id,
      :ephemeral_key,
      :key_header,
      :status,
      :delivered_at,
      :read_at,
      :push_sent_at
    ])
    |> validate_required([:id, :message_id, :recipient_device_id, :key_header])
    |> validate_inclusion(:status, ["pending", "delivered", "read", "failed"])
  end
end
