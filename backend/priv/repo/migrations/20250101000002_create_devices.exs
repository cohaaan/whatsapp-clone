defmodule Chat.Repo.Migrations.CreateDevices do
  use Ecto.Migration

  def change do
    create table(:devices, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :push_token, :text
      add :platform, :string, null: false
      add :device_name, :text
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:devices, [:user_id])
    create index(:devices, [:push_token])

    # For checking device presence/activity
    create index(:devices, [:last_seen_at])

    # Enforce platform values
    create constraint(:devices, :platform_must_be_valid,
      check: "platform IN ('ios', 'android')"
    )
  end
end
