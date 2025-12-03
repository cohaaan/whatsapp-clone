defmodule ChatWeb.HealthController do
  use ChatWeb, :controller

  @doc """
  Health check endpoint.
  GET /api/health
  """
  def check(conn, _params) do
    # Check database connection
    case check_database() do
      :ok ->
        json(conn, %{
          status: "healthy",
          timestamp: DateTime.utc_now(),
          checks: %{
            database: "ok",
            application: "ok"
          }
        })

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{
          status: "unhealthy",
          timestamp: DateTime.utc_now(),
          checks: %{
            database: "error",
            error: inspect(reason)
          }
        })
    end
  end

  defp check_database do
    try do
      Chat.Repo.query("SELECT 1", [])
      :ok
    rescue
      e -> {:error, e}
    end
  end
end
