defmodule Chat.Accounts.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "devices" do
    field :push_token, :string
    field :platform, :string
    field :device_name, :string
    field :last_seen_at, :utc_datetime_usec

    belongs_to :user, Chat.Accounts.User, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(device, attrs) do
    device
    |> cast(attrs, [:user_id, :push_token, :platform, :device_name, :last_seen_at])
    |> validate_required([:user_id, :platform])
    |> validate_inclusion(:platform, ["ios", "android"])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Create a new device registration.
  """
  def registration_changeset(device, attrs) do
    device
    |> cast(attrs, [:user_id, :platform, :device_name, :push_token])
    |> validate_required([:user_id, :platform])
    |> validate_inclusion(:platform, ["ios", "android"])
    |> put_change(:last_seen_at, DateTime.utc_now())
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Update push token.
  """
  def update_push_token_changeset(device, push_token) do
    device
    |> cast(%{push_token: push_token}, [:push_token])
    |> validate_required([:push_token])
  end

  @doc """
  Update last seen timestamp.
  """
  def touch_last_seen_changeset(device) do
    device
    |> cast(%{}, [])
    |> put_change(:last_seen_at, DateTime.utc_now())
  end
end
