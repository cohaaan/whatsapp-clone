defmodule Chat.Repo.Migrations.CreateSenderKeys do
  use Ecto.Migration

  def change do
    create table(:sender_keys, primary_key: false) do
      add :conversation_id, references(:conversations, type: :uuid, on_delete: :delete_all),
        null: false, primary_key: true
      add :sender_device_id, references(:devices, type: :uuid, on_delete: :delete_all),
        null: false, primary_key: true

      # Distribution ID for this sender key version
      add :distribution_id, :uuid, null: false

      # Encrypted chain key (server stores for recovery scenarios)
      add :chain_key, :bytea, null: false

      # Chain iteration counter
      add :iteration, :integer, null: false, default: 0

      # Track when key was created/rotated
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Find sender keys for a group
    create index(:sender_keys, [:conversation_id])

    # Track sender key rotation
    create index(:sender_keys, [:sender_device_id, :inserted_at])
  end
end
