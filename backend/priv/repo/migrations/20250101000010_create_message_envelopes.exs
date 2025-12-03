defmodule Chat.Repo.Migrations.CreateMessageEnvelopes do
  use Ecto.Migration

  def change do
    create table(:message_envelopes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :message_id, :uuid, null: false
      add :recipient_device_id, references(:devices, type: :uuid, on_delete: :delete_all),
        null: false

      # Ephemeral key used for this specific message (X3DH)
      add :ephemeral_key, :bytea

      # Encrypted message key (small, ~100 bytes even for groups)
      # Contains the key needed to decrypt the payload
      add :key_header, :bytea, null: false

      add :status, :string, null: false, default: "pending"
      add :delivered_at, :utc_datetime_usec
      add :read_at, :utc_datetime_usec
      add :push_sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:message_envelopes, [:message_id])

    # Critical index: find pending deliveries for a device (used in offline queue)
    create index(:message_envelopes, [:recipient_device_id, :status],
      where: "status = 'pending'",
      name: :message_envelopes_pending_idx
    )

    create index(:message_envelopes, [:recipient_device_id, :delivered_at])

    create constraint(:message_envelopes, :status_must_be_valid,
      check: "status IN ('pending', 'delivered', 'read', 'failed')"
    )
  end
end
