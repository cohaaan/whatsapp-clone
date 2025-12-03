defmodule Chat.Messaging.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "conversations" do
    field :type, :string
    field :name, :string

    belongs_to :created_by, Chat.Accounts.User, type: :binary_id, define_field: false
    field :created_by_user_id, :binary_id

    has_many :messages, Chat.Messaging.Message

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:type, :name, :created_by_user_id])
    |> validate_required([:type])
    |> validate_inclusion(:type, ["dm", "group"])
  end
end
