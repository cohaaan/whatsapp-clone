defmodule Chat.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :type, :string, null: false
      add :name, :text
      add :created_by, references(:users, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:conversations, [:created_by])
    create index(:conversations, [:type])

    create constraint(:conversations, :type_must_be_valid,
      check: "type IN ('dm', 'group')"
    )
  end
end
