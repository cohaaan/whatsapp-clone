defmodule ChatWeb.Router do
  use ChatWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      "content-security-policy" => "default-src 'none'"
    }
  end

  pipeline :authenticated do
    plug ChatWeb.Plugs.AuthenticateJWT
  end

  scope "/api", ChatWeb do
    pipe_through :api

    # Public endpoints
    post "/auth/request_otp", AuthController, :request_otp
    post "/auth/verify_otp", AuthController, :verify_otp
    post "/auth/register", AuthController, :register

    # Health check
    get "/health", HealthController, :check
  end

  scope "/api", ChatWeb do
    pipe_through [:api, :authenticated]

    # Auth
    post "/auth/refresh", AuthController, :refresh
    delete "/auth/logout", AuthController, :logout

    # Devices
    get "/devices/:id", DeviceController, :show
    patch "/devices/:id", DeviceController, :update
    post "/devices/:id/prekeys", DeviceController, :upload_prekeys
    get "/devices/:id/prekey_count", DeviceController, :prekey_count
    get "/devices/:id/prekey_bundle", DeviceController, :prekey_bundle

    # Conversations
    get "/conversations", ConversationController, :index
    post "/conversations", ConversationController, :create
    get "/conversations/:id", ConversationController, :show
    get "/conversations/:id/messages", ConversationController, :messages

    # Messages (REST fallback, primary is via Channel)
    post "/messages", MessageController, :create
  end

  # Phoenix LiveDashboard
  import Phoenix.LiveDashboard.Router

  scope "/admin" do
    pipe_through [:api, :authenticated]
    live_dashboard "/dashboard", metrics: ChatWeb.Telemetry
  end

  # PromEx metrics endpoint
  scope "/" do
    pipe_through :api
    forward "/metrics", Chat.PromEx
  end
end
