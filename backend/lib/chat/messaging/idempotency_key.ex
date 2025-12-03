defmodule Chat.Messaging.IdempotencyKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  @foreign_key_type :binary_id

  schema "idempotency_keys" do
    field :message_id, :binary_id
    belongs_to :user, Chat.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(idempotency_key, attrs) do
    idempotency_key
    |> cast(attrs, [:key, :user_id, :message_id])
    |> validate_required([:key, :user_id, :message_id])
    |> unique_constraint(:key, name: :idempotency_keys_pkey)
  end
end
