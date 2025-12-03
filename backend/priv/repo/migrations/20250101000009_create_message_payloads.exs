defmodule Chat.Repo.Migrations.CreateMessagePayloads do
  use Ecto.Migration

  def change do
    create table(:message_payloads, primary_key: false) do
      # For sender_key messages: ONE row with the Sender Key-encrypted blob
      # For pairwise messages: Can have multiple rows (one per recipient device)
      add :message_id, :uuid, null: false
      add :recipient_device_id, :uuid
      add :ciphertext, :bytea, null: false

      # Composite primary key handles both cases:
      # - sender_key: (message_id, NULL)
      # - pairwise: (message_id, recipient_device_id)
      add :id, :uuid, primary_key: true
    end

    create index(:message_payloads, [:message_id])
    create index(:message_payloads, [:recipient_device_id])
  end
end
