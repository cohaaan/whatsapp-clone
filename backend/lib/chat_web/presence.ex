defmodule ChatWeb.Presence do
  @moduledoc """
  Phoenix Presence for tracking online devices.
  """

  use Phoenix.Presence,
    otp_app: :chat,
    pubsub_server: Chat.PubSub
end
