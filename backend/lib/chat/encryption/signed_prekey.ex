defmodule Chat.Encryption.SignedPrekey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "signed_prekeys" do
    field :device_id, :binary_id, primary_key: true
    field :key_id, :integer, primary_key: true
    field :public_key, :binary
    field :signature, :binary

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(prekey, attrs) do
    prekey
    |> cast(attrs, [:device_id, :key_id, :public_key, :signature])
    |> validate_required([:device_id, :key_id, :public_key, :signature])
    |> foreign_key_constraint(:device_id)
  end
end
