import Config

# Runtime configuration (loaded at runtime, not compile time)

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") == "true", do: [:inet6], else: []

  config :chat, Chat.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "25"),
    queue_target: 50,
    queue_interval: 1000,
    timeout: 15_000,
    socket_options: maybe_ipv6

  # Phoenix Endpoint configuration
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :chat, ChatWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    server: true

  # APNs Configuration (Token-based auth with p8 key)
  apns_key_id = System.get_env("APNS_KEY_ID")
  apns_team_id = System.get_env("APNS_TEAM_ID")
  apns_p8_file_path = System.get_env("APNS_P8_FILE_PATH")

  if apns_key_id && apns_team_id && apns_p8_file_path do
    config :pigeon, :apns,
      apns_default: %{
        key: apns_p8_file_path,
        key_identifier: apns_key_id,
        team_id: apns_team_id,
        mode: :prod,
        port: 443,
        pool_size: 10,
        reconnect: true
      }
  end

  # FCM Configuration (v1 HTTP API with service account)
  fcm_service_account_json = System.get_env("FCM_SERVICE_ACCOUNT_JSON")

  if fcm_service_account_json do
    config :pigeon, :fcm,
      fcm_default: %{
        service_account_json: fcm_service_account_json,
        port: 443,
        pool_size: 10,
        reconnect: true
      }
  end

  # JWT Configuration
  jwt_secret =
    System.get_env("JWT_SECRET") ||
      raise """
      environment variable JWT_SECRET is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :chat, Chat.Auth,
    jwt_secret: jwt_secret,
    access_token_ttl: 15 * 60,
    # 15 minutes
    refresh_token_ttl: 7 * 24 * 60 * 60

  # 7 days

  # Hammer (rate limiting) - use ETS backend
  config :hammer,
    backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}
end

if config_env() == :dev do
  config :chat, Chat.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "chat_dev",
    stacktrace: true,
    show_sensitive_data_on_connection_error: true,
    pool_size: 10

  config :chat, ChatWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4000],
    check_origin: false,
    code_reloader: true,
    debug_errors: true,
    secret_key_base: "development_secret_key_base_at_least_64_bytes_long_please",
    watchers: []

  config :hammer,
    backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}

  # JWT in dev
  config :chat, Chat.Auth,
    jwt_secret: "dev_jwt_secret_at_least_32_bytes",
    access_token_ttl: 15 * 60,
    refresh_token_ttl: 7 * 24 * 60 * 60
end

if config_env() == :test do
  config :chat, Chat.Repo,
    username: "postgres",
    password: "postgres",
    hostname: "localhost",
    database: "chat_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: 10

  config :chat, ChatWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4002],
    secret_key_base: "test_secret_key_base_at_least_64_bytes_long_please",
    server: false

  config :chat, Chat.Auth,
    jwt_secret: "test_jwt_secret_at_least_32_bytes",
    access_token_ttl: 15 * 60,
    refresh_token_ttl: 7 * 24 * 60 * 60
end
