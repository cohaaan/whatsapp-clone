defmodule Chat.Encryption.IdentityKey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "identity_keys" do
    field :device_id, :binary_id, primary_key: true
    field :identity_public_key, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(identity_key, attrs) do
    identity_key
    |> cast(attrs, [:device_id, :identity_public_key])
    |> validate_required([:device_id, :identity_public_key])
    |> foreign_key_constraint(:device_id)
  end
end
