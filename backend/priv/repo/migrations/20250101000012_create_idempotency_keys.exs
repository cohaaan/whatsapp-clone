defmodule Chat.Repo.Migrations.CreateIdempotencyKeys do
  use Ecto.Migration

  def change do
    create table(:idempotency_keys, primary_key: false) do
      add :key, :text, primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :message_id, :uuid, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # L2 cache cleanup: TTL index for automatic expiry (24h)
    # Postgres doesn't have TTL natively, but this partial index helps queries
    # Cleanup job will: DELETE FROM idempotency_keys WHERE inserted_at < now() - interval '24 hours'
    create index(:idempotency_keys, [:inserted_at],
      where: "inserted_at > NOW() - INTERVAL '24 hours'",
      name: :idempotency_keys_ttl_idx
    )

    create index(:idempotency_keys, [:user_id])
  end
end
