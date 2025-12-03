defmodule ChatWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :chat

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_chat_key",
    signing_salt: "chat_signing_salt",
    same_site: "Lax"
  end

  socket "/socket", ChatWeb.UserSocket,
    websocket: [
      connect_info: [:peer_data, :x_headers],
      timeout: 45_000,
      max_frame_size: 8_000_000
    ],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  plug Plug.Static,
    at: "/",
    from: :chat,
    gzip: false,
    only: ChatWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :chat
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Rate limiter for unauthenticated endpoints
  plug ChatWeb.Plugs.RateLimiter

  plug ChatWeb.Router
end
