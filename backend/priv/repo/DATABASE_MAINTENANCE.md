# Database Maintenance Strategy

## Automated Partition Management

### pg_partman Daily Maintenance
Run this daily via cron or Oban scheduled job:

```sql
SELECT partman.run_maintenance('public.messages');
```

This will:
- Create new monthly partitions 4 months in advance
- Archive partitions older than 12 months
- Update partition constraints

### Monitoring Partition Health
```sql
SELECT
  parent_table,
  partition_type,
  datetime_string,
  last_partition_name,
  premake,
  retention
FROM partman.part_config;
```

## Index Maintenance

### REINDEX Strategy
Never run REINDEX on production during peak hours. Use REINDEX CONCURRENTLY (Postgres 12+):

```sql
-- Reindex high-write tables monthly (run during low-traffic window)
REINDEX INDEX CONCURRENTLY message_envelopes_pending_idx;
REINDEX INDEX CONCURRENTLY messages_conversation_time_idx;
REINDEX INDEX CONCURRENTLY one_time_prekeys_unused_idx;
```

### Index Bloat Monitoring
Check index bloat monthly:

```sql
SELECT
  schemaname,
  tablename,
  indexname,
  pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```

If `idx_scan` is 0 for an index, consider dropping it.

## Vacuum & Analyze Scheduling

### Autovacuum Tuning (postgresql.conf)
For high-write tables, tune autovacuum aggression:

```conf
# Base autovacuum settings
autovacuum = on
autovacuum_max_workers = 6
autovacuum_naptime = 15s

# Aggressive settings for high-write tables
# Apply via ALTER TABLE for messages, message_envelopes, idempotency_keys
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02
autovacuum_vacuum_cost_limit = 2000
```

Apply to specific tables:

```sql
ALTER TABLE message_envelopes SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02,
  autovacuum_vacuum_cost_limit = 2000
);

ALTER TABLE messages SET (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_analyze_scale_factor = 0.02
);

ALTER TABLE idempotency_keys SET (
  autovacuum_vacuum_scale_factor = 0.1
);
```

### Manual VACUUM ANALYZE
Run weekly during maintenance window:

```sql
VACUUM ANALYZE messages;
VACUUM ANALYZE message_envelopes;
VACUUM ANALYZE idempotency_keys;
VACUUM ANALYZE pending_deliveries;
```

### Monitoring Vacuum Performance
```sql
SELECT
  schemaname,
  relname,
  last_vacuum,
  last_autovacuum,
  last_analyze,
  last_autoanalyze,
  n_dead_tup,
  n_live_tup
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

## Cleanup Jobs

### Idempotency Keys Cleanup (Daily)
```sql
DELETE FROM idempotency_keys
WHERE inserted_at < NOW() - INTERVAL '24 hours';
```

Implement as Oban job:

```elixir
defmodule Chat.Workers.CleanupIdempotencyKeys do
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def perform(_job) do
    {count, _} = Repo.delete_all(
      from i in IdempotencyKey,
      where: i.inserted_at < ago(24, "hour")
    )

    Logger.info("Cleaned up #{count} expired idempotency keys")
    :ok
  end
end
```

### Expired Device Sessions Cleanup (Daily)
```sql
DELETE FROM device_sessions
WHERE expires_at < NOW();
```

### Old Message Envelopes (Optional - 90 days retention)
For delivered/read messages older than 90 days, you can clean envelopes to save space:

```sql
DELETE FROM message_envelopes
WHERE status IN ('delivered', 'read')
  AND inserted_at < NOW() - INTERVAL '90 days';
```

⚠️ **Warning**: Only do this if you don't need delivery status history beyond 90 days.

## Connection Pool Monitoring

Monitor Ecto pool status in production:

```elixir
iex> :ecto_sql.pool_status(Chat.Repo)
%{size: 25, available: 18, busy: 7}
```

Alert if `available < 3` for > 1 minute (pool exhaustion).

## Query Performance Monitoring

### Slow Query Log (postgresql.conf)
```conf
log_min_duration_statement = 100  # Log queries slower than 100ms
log_statement = 'none'
log_duration = off
```

### pg_stat_statements Extension
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Find slowest queries
SELECT
  query,
  calls,
  mean_exec_time,
  max_exec_time,
  stddev_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 20;
```

## Backup Strategy

### Daily Basebackup + WAL Archiving
```bash
#!/bin/bash
# Fly.io handles this automatically for Postgres volumes
# For self-hosted, use pg_basebackup:

pg_basebackup -D /backup/$(date +%Y%m%d) \
  -Fp -Xs -P -h localhost -U postgres
```

### Point-in-Time Recovery (PITR)
Enable WAL archiving in postgresql.conf:

```conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /archive/%f && cp %p /archive/%f'
archive_timeout = 300  # Archive WAL every 5 minutes
```

## Emergency Procedures

### High CPU from Autovacuum
If autovacuum is consuming excessive CPU:

```sql
-- Find running autovacuum processes
SELECT pid, age(clock_timestamp(), query_start), query
FROM pg_stat_activity
WHERE query LIKE 'autovacuum:%';

-- Terminate specific autovacuum (last resort)
SELECT pg_terminate_backend(pid);
```

### Connection Pool Exhausted
Temporary increase:

```elixir
# config/runtime.exs
pool_size = String.to_integer(System.get_env("POOL_SIZE") || "50")  # Increase from 25
```

Then restart application. Investigate root cause (missing indexes, slow queries).

### Partition Not Created
If pg_partman fails to create next month's partition:

```sql
-- Manually create partition
CREATE TABLE messages_202512 PARTITION OF messages
FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');

-- Recreate index
CREATE INDEX messages_202512_conversation_time_idx
ON messages_202512 (conversation_id, inserted_at DESC);
```
