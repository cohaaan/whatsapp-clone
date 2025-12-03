defmodule Chat.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :phone_hash, :bytea, null: false
      add :phone_encrypted, :bytea, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:users, [:phone_hash])

    # Track account creation to prevent abuse (3 accounts per phone per year)
    create index(:users, [:phone_hash, :inserted_at])
  end
end
