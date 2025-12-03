defmodule Chat.Repo.Migrations.CreateDeviceSessions do
  use Ecto.Migration

  def change do
    create table(:device_sessions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :device_id, references(:devices, type: :uuid, on_delete: :delete_all), null: false

      # Store bcrypt hash of refresh token (not the token itself)
      add :refresh_token_hash, :text, null: false

      add :expires_at, :utc_datetime_usec, null: false
      add :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:device_sessions, [:device_id])
    create index(:device_sessions, [:expires_at])
    create unique_index(:device_sessions, [:refresh_token_hash])
  end
end
