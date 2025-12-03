defmodule Chat.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :phone_hash, :binary
    field :phone_encrypted, :binary
    field :name, :string, virtual: true  # Not stored, for display only

    has_many :devices, Chat.Accounts.Device

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:phone_hash, :phone_encrypted])
    |> validate_required([:phone_hash, :phone_encrypted])
    |> unique_constraint(:phone_hash)
  end

  @doc """
  Create changeset from phone number (hashes and encrypts).
  """
  def registration_changeset(user, phone_number) do
    phone_hash = hash_phone(phone_number)
    phone_encrypted = encrypt_phone(phone_number)

    user
    |> cast(%{}, [])
    |> put_change(:phone_hash, phone_hash)
    |> put_change(:phone_encrypted, phone_encrypted)
    |> unique_constraint(:phone_hash)
  end

  defp hash_phone(phone) do
    normalized = normalize_phone(phone)
    Bcrypt.hash_pwd_salt(normalized)
  end

  defp encrypt_phone(phone) do
    normalized = normalize_phone(phone)
    # AES-GCM encryption with server key
    secret_key = get_encryption_key()

    # Simple encryption for demo - in production use proper AES-GCM
    :crypto.crypto_one_time(:aes_256_gcm, secret_key,
      :crypto.strong_rand_bytes(12), normalized, true)
  end

  defp normalize_phone(phone) do
    # Remove all non-digits
    phone
    |> String.replace(~r/\D/, "")
    |> String.trim_leading("0")
  end

  defp get_encryption_key do
    # In production, load from secure env var
    key = Application.get_env(:chat, :phone_encryption_key) ||
          String.duplicate("0", 32)

    <<key::binary-size(32)>>
  end

  @doc """
  Verify if phone number matches stored hash.
  """
  def verify_phone?(user, phone_number) do
    normalized = normalize_phone(phone_number)
    Bcrypt.verify_pass(normalized, user.phone_hash)
  end
end
