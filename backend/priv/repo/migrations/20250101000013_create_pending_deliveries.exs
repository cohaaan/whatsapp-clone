defmodule Chat.Repo.Migrations.CreatePendingDeliveries do
  use Ecto.Migration

  def change do
    create table(:pending_deliveries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :envelope_id, references(:message_envelopes, type: :uuid, on_delete: :delete_all),
        null: false
      add :device_id, references(:devices, type: :uuid, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Critical index: drain offline queue when device connects
    create index(:pending_deliveries, [:device_id, :inserted_at])

    create index(:pending_deliveries, [:envelope_id])

    # Ensure no duplicate entries in queue
    create unique_index(:pending_deliveries, [:envelope_id, :device_id])
  end
end
