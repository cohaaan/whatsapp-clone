defmodule Chat.Push.PendingProducer do
  @moduledoc """
  Broadway producer that polls pending_deliveries for offline devices.

  Alternative approach: Subscribe to PubSub topic "push:pending"
  and consume events in real-time.
  """

  use GenStage

  alias Chat.Repo
  alias Chat.Messaging.MessageEnvelope

  import Ecto.Query

  @poll_interval :timer.seconds(5)

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    # Start polling
    schedule_poll()

    {:producer, %{demand: 0, pending: []}}
  end

  @impl true
  def handle_demand(demand, state) do
    new_demand = state.demand + demand
    dispatch_events(%{state | demand: new_demand})
  end

  @impl true
  def handle_info(:poll, state) do
    # Fetch pending deliveries that need push notifications
    envelopes = fetch_pending_push_envelopes()

    schedule_poll()

    new_pending = state.pending ++ envelopes
    dispatch_events(%{state | pending: new_pending})
  end

  defp dispatch_events(%{demand: 0} = state) do
    {:noreply, [], state}
  end

  defp dispatch_events(%{demand: demand, pending: pending} = state) do
    {to_dispatch, remaining} = Enum.split(pending, demand)

    new_demand = demand - length(to_dispatch)

    {:noreply, to_dispatch, %{state | demand: new_demand, pending: remaining}}
  end

  defp fetch_pending_push_envelopes do
    # Find envelopes that are pending and haven't had a push sent yet
    # and were created > 10 seconds ago (grace period for device to connect)
    cutoff = DateTime.add(DateTime.utc_now(), -10, :second)

    query =
      from e in MessageEnvelope,
        where:
          e.status == "pending" and
            is_nil(e.push_sent_at) and
            e.inserted_at < ^cutoff,
        limit: 1000,
        preload: [:recipient_device]

    Repo.all(query)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
