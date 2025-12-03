defmodule Chat.Accounts.DeviceSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "device_sessions" do
    field :refresh_token_hash, :string
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :device, Chat.Accounts.Device, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:device_id, :refresh_token_hash, :expires_at, :last_used_at])
    |> validate_required([:device_id, :refresh_token_hash, :expires_at])
    |> foreign_key_constraint(:device_id)
    |> unique_constraint(:refresh_token_hash)
  end

  @doc """
  Update last_used_at timestamp.
  """
  def touch_last_used_changeset(session) do
    session
    |> cast(%{}, [])
    |> put_change(:last_used_at, DateTime.utc_now())
  end
end
