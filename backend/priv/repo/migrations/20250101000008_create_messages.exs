defmodule Chat.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def up do
    # Create messages table - will be partitioned by range on inserted_at
    execute """
    CREATE TABLE messages (
      id UUID NOT NULL,
      conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      sender_device_id UUID NOT NULL REFERENCES devices(id) ON DELETE SET NULL,
      message_type VARCHAR(20) NOT NULL CHECK (message_type IN ('pairwise', 'sender_key')),
      content_type SMALLINT NOT NULL DEFAULT 0,
      client_timestamp TIMESTAMP(6) WITH TIME ZONE NOT NULL,
      inserted_at TIMESTAMP(6) WITH TIME ZONE NOT NULL DEFAULT NOW(),
      PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """

    # Create initial partition for current month
    # In production, pg_partman will auto-create monthly partitions
    current_month_start = ~D[2025-01-01]
    next_month_start = ~D[2025-02-01]

    execute """
    CREATE TABLE messages_202501 PARTITION OF messages
    FOR VALUES FROM ('#{current_month_start}') TO ('#{next_month_start}')
    """

    # Critical index for conversation message queries
    execute """
    CREATE INDEX messages_conversation_time_idx
    ON messages (conversation_id, inserted_at DESC)
    """

    # content_type enum values:
    # 0 = text
    # 1 = image
    # 2 = video
    # 3 = audio
    # 10 = system_event (e.g., user joined, left)
    # 20 = ephemeral (disappearing message)
    execute "CREATE INDEX messages_content_type_idx ON messages (content_type)"
  end

  def down do
    execute "DROP TABLE IF EXISTS messages CASCADE"
  end
end
