defmodule Chat.Messaging.MessagePayload do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "message_payloads" do
    field :ciphertext, :binary

    belongs_to :message, Chat.Messaging.Message, type: :binary_id, define_field: false
    field :message_id, :binary_id

    belongs_to :recipient_device, Chat.Accounts.Device, type: :binary_id, define_field: false
    field :recipient_device_id, :binary_id
  end

  @doc false
  def changeset(payload, attrs) do
    payload
    |> cast(attrs, [:id, :message_id, :recipient_device_id, :ciphertext])
    |> validate_required([:id, :message_id, :ciphertext])
  end
end
