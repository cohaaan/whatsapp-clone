defmodule Chat.Repo.Migrations.CreateIdentityKeys do
  use Ecto.Migration

  def change do
    create table(:identity_keys, primary_key: false) do
      add :device_id, references(:devices, type: :uuid, on_delete: :delete_all),
        primary_key: true
      add :identity_public_key, :bytea, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
