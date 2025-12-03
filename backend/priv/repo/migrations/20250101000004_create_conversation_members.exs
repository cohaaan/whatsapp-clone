defmodule Chat.Repo.Migrations.CreateConversationMembers do
  use Ecto.Migration

  def change do
    create table(:conversation_members, primary_key: false) do
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        null: false, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false, primary_key: true
      add :role, :string, null: false, default: "member"
      add :joined_at, :utc_datetime_usec, null: false
      add :left_at, :utc_datetime_usec
    end

    create index(:conversation_members, [:user_id])
    create index(:conversation_members, [:conversation_id, :left_at])

    create constraint(:conversation_members, :role_must_be_valid,
      check: "role IN ('admin', 'member')"
    )
  end
end
