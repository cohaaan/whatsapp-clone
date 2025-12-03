defmodule Chat.Encryption.OneTimePrekey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "one_time_prekeys" do
    field :key_id, :integer
    field :public_key, :binary
    field :used, :boolean, default: false

    belongs_to :device, Chat.Accounts.Device, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(prekey, attrs) do
    prekey
    |> cast(attrs, [:device_id, :key_id, :public_key, :used])
    |> validate_required([:device_id, :key_id, :public_key])
    |> foreign_key_constraint(:device_id)
    |> unique_constraint([:device_id, :key_id])
  end
end
