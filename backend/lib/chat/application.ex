defmodule Chat.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Telemetry
      ChatWeb.Telemetry,

      # Database
      Chat.Repo,

      # PubSub
      {Phoenix.PubSub, name: Chat.PubSub},

      # Presence
      ChatWeb.Presence,

      # Idempotency Cache (L1 - ETS)
      Chat.Cache.Idempotency,

      # Push Notification Pipeline
      Chat.Push.BroadwayPipeline,

      # Finch HTTP Client
      {Finch, name: Chat.Finch},

      # DNSCluster (for multi-node discovery on Fly.io)
      {DNSCluster, query: Application.get_env(:chat, :dns_cluster_query) || :ignore},

      # Phoenix Endpoint
      ChatWeb.Endpoint,

      # Background Jobs (optional, for scheduled tasks)
      # {Oban, Application.fetch_env!(:chat, Oban)}
    ]

    opts = [strategy: :one_for_one, name: Chat.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ChatWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
