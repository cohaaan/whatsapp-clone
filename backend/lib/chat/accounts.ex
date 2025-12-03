defmodule Chat.Accounts do
  @moduledoc """
  The Accounts context manages users and devices.
  """

  import Ecto.Query
  require Logger

  alias Chat.Repo
  alias Chat.Accounts.{User, Device}

  ## Users

  @doc """
  Get user by ID.
  """
  def get_user(id) do
    Repo.get(User, id)
  end

  @doc """
  Get user by phone number (searches by hash).
  """
  def get_user_by_phone(phone_number) do
    # Normalize phone and check against all users
    # This is inefficient but necessary since we can't hash query bcrypt
    # In production, consider storing a searchable phone hash separately
    normalized = normalize_phone(phone_number)

    users = Repo.all(User)

    Enum.find(users, fn user ->
      Bcrypt.verify_pass(normalized, user.phone_hash)
    end)
  end

  @doc """
  Create a new user.
  """
  def create_user(phone_number) do
    %User{}
    |> User.registration_changeset(phone_number)
    |> Repo.insert()
  end

  @doc """
  Check if user exists by phone number.
  """
  def user_exists?(phone_number) do
    get_user_by_phone(phone_number) != nil
  end

  @doc """
  Get or create user by phone number.
  """
  def get_or_create_user(phone_number) do
    case get_user_by_phone(phone_number) do
      nil -> create_user(phone_number)
      user -> {:ok, user}
    end
  end

  @doc """
  Check account creation limits (3 accounts per phone per year).
  """
  def check_account_creation_limit(phone_number) do
    one_year_ago = DateTime.add(DateTime.utc_now(), -365, :day)

    # This is simplified - in production, track in separate table
    case get_user_by_phone(phone_number) do
      nil -> :ok
      user ->
        if DateTime.compare(user.inserted_at, one_year_ago) == :gt do
          {:error, :account_limit_reached}
        else
          :ok
        end
    end
  end

  ## Devices

  @doc """
  Get device by ID.
  """
  def get_device(id) do
    Repo.get(Device, id)
  end

  @doc """
  Get all devices for a user.
  """
  def list_user_devices(user_id) do
    Repo.all(from d in Device, where: d.user_id == ^user_id, order_by: [desc: d.inserted_at])
  end

  @doc """
  Create a new device.
  """
  def create_device(attrs) do
    %Device{}
    |> Device.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update device.
  """
  def update_device(device, attrs) do
    device
    |> Device.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Update device push token.
  """
  def update_device_push_token(device, push_token) do
    device
    |> Device.update_push_token_changeset(push_token)
    |> Repo.update()
  end

  @doc """
  Update device last_seen_at timestamp.
  """
  def update_device_last_seen(device) do
    device
    |> Device.touch_last_seen_changeset()
    |> Repo.update()
  end

  @doc """
  Delete a device.
  """
  def delete_device(device) do
    Repo.delete(device)
  end

  ## Helpers

  defp normalize_phone(phone) do
    phone
    |> String.replace(~r/\D/, "")
    |> String.trim_leading("0")
  end
end
