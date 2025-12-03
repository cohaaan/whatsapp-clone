defmodule Chat.Repo.Migrations.CreateSignedPrekeys do
  use Ecto.Migration

  def change do
    create table(:signed_prekeys, primary_key: false) do
      add :device_id, references(:devices, type: :uuid, on_delete: :delete_all),
        null: false, primary_key: true
      add :key_id, :integer, null: false, primary_key: true
      add :public_key, :bytea, null: false
      add :signature, :bytea, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:signed_prekeys, [:device_id, :inserted_at])
  end
end
