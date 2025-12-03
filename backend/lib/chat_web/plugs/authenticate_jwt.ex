defmodule ChatWeb.Plugs.AuthenticateJWT do
  @moduledoc """
  Plug to authenticate requests using JWT from Authorization header.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- Chat.Auth.verify_access_token(token) do
      # Add user_id and device_id to conn assigns
      conn
      |> assign(:user_id, claims["sub"])
      |> assign(:device_id, claims["device_id"])
      |> assign(:current_user_claims, claims)
    else
      [] ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "missing_authorization_header"})
        |> halt()

      {:error, :expired} ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "token_expired"})
        |> halt()

      {:error, reason} ->
        Logger.warning("JWT verification failed: #{inspect(reason)}")

        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "invalid_token"})
        |> halt()
    end
  end
end
