defmodule Chat.Cache.Idempotency do
  @moduledoc """
  Two-tier idempotency cache for high-performance duplicate detection.

  L1: ETS (in-memory, microseconds latency)
  L2: Postgres (durable, milliseconds latency)

  Flow:
  1. Check ETS (L1)
  2. On L1 miss → check Postgres (L2)
  3. On L2 miss → insert to BOTH L1 and L2
  4. On hit → reject as duplicate

  ETS entries expire after 5 minutes (cleanup via GenServer).
  Postgres entries expire after 24 hours (cleanup via Oban).
  """

  use GenServer
  require Logger

  alias Chat.Repo
  alias Chat.Messaging.IdempotencyKey

  @table :idempotency_cache
  @cleanup_interval :timer.seconds(60)
  @ets_ttl :timer.minutes(5)

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check idempotency and insert if not duplicate.

  Returns:
  - {:ok, message_id} if key doesn't exist (inserted to both L1 and L2)
  - {:error, :duplicate} if key exists in either L1 or L2
  """
  def check_and_insert(idempotency_key, user_id, message_id) do
    # L1: Check ETS
    case :ets.lookup(@table, idempotency_key) do
      [{^idempotency_key, _stored_message_id, _inserted_at}] ->
        Logger.debug("L1 cache hit for idempotency_key: #{idempotency_key}")
        {:error, :duplicate}

      [] ->
        # L1 miss, check L2 (Postgres)
        check_and_insert_l2(idempotency_key, user_id, message_id)
    end
  end

  @doc """
  Manually invalidate a key from L1 cache (rare, for testing or corrections).
  """
  def invalidate(idempotency_key) do
    :ets.delete(@table, idempotency_key)
    :ok
  end

  @doc """
  Get cache stats for monitoring.
  """
  def stats do
    info = :ets.info(@table)

    %{
      size: info[:size],
      memory_bytes: info[:memory] * :erlang.system_info(:wordsize)
    }
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Schedule periodic cleanup
    schedule_cleanup()

    Logger.info("Idempotency cache (L1) started")

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp check_and_insert_l2(idempotency_key, user_id, message_id) do
    # Try to insert into Postgres (L2)
    changeset =
      IdempotencyKey.changeset(%IdempotencyKey{}, %{
        key: idempotency_key,
        user_id: user_id,
        message_id: message_id
      })

    case Repo.insert(changeset) do
      {:ok, _} ->
        # L2 insert successful, also insert to L1
        insert_to_l1(idempotency_key, message_id)
        {:ok, message_id}

      {:error, %Ecto.Changeset{errors: [key: {"has already been taken", _}]}} ->
        # L2 duplicate found
        Logger.debug("L2 cache hit for idempotency_key: #{idempotency_key}")

        # Backfill L1 for future requests
        case Repo.get_by(IdempotencyKey, key: idempotency_key) do
          %IdempotencyKey{message_id: stored_message_id} ->
            insert_to_l1(idempotency_key, stored_message_id)

          nil ->
            # Race condition: entry deleted between insert and get
            Logger.warning("L2 duplicate but not found on backfill: #{idempotency_key}")
        end

        {:error, :duplicate}

      {:error, reason} ->
        Logger.error("Failed to insert idempotency key to L2: #{inspect(reason)}")
        {:error, :database_error}
    end
  end

  defp insert_to_l1(idempotency_key, message_id) do
    now = System.system_time(:millisecond)
    :ets.insert(@table, {idempotency_key, message_id, now})
  end

  defp cleanup_expired_entries do
    now = System.system_time(:millisecond)
    cutoff = now - @ets_ttl

    # Delete entries older than TTL
    match_spec = [
      {
        {:"$1", :"$2", :"$3"},
        [{:<, :"$3", cutoff}],
        [true]
      }
    ]

    deleted_count = :ets.select_delete(@table, match_spec)

    if deleted_count > 0 do
      Logger.debug("Cleaned up #{deleted_count} expired idempotency keys from L1 cache")
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
