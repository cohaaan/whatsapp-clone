defmodule Chat.Repo.Migrations.SetupPgPartman do
  use Ecto.Migration

  def up do
    # Enable pg_partman extension
    execute "CREATE EXTENSION IF NOT EXISTS pg_partman"

    # Configure pg_partman for messages table
    # This will auto-create monthly partitions 4 months ahead, maintain 12 months back
    execute """
    SELECT partman.create_parent(
      p_parent_table := 'public.messages',
      p_control := 'inserted_at',
      p_type := 'native',
      p_interval := '1 month',
      p_premake := 4,
      p_start_partition := '2025-01-01'
    )
    """

    # Configure retention policy (keep 12 months, archive older)
    execute """
    UPDATE partman.part_config
    SET
      retention = '12 months',
      retention_keep_table = true,
      retention_keep_index = false
    WHERE parent_table = 'public.messages'
    """

    # Add to maintenance schedule (run daily via cron or background job)
    # In production: SELECT partman.run_maintenance('public.messages')
  end

  def down do
    execute "SELECT partman.undo_partition('public.messages', 20)"
    execute "DROP EXTENSION IF EXISTS pg_partman CASCADE"
  end
end
