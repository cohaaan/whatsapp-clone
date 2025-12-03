defmodule Chat.Encryption do
  @moduledoc """
  Manages cryptographic keys for Signal Protocol.
  """

  import Ecto.Query
  alias Chat.Repo

  @doc """
  Store identity public key for a device.
  """
  def store_identity_key(device_id, public_key) when is_binary(public_key) do
    attrs = %{
      device_id: device_id,
      identity_public_key: Base.decode64!(public_key)
    }

    %Chat.Encryption.IdentityKey{}
    |> Chat.Encryption.IdentityKey.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: :device_id)
  end

  @doc """
  Store signed prekey.
  """
  def store_signed_prekey(device_id, %{"key_id" => key_id, "public_key" => public_key, "signature" => signature}) do
    attrs = %{
      device_id: device_id,
      key_id: key_id,
      public_key: Base.decode64!(public_key),
      signature: Base.decode64!(signature)
    }

    %Chat.Encryption.SignedPrekey{}
    |> Chat.Encryption.SignedPrekey.changeset(attrs)
    |> Repo.insert(on_conflict: :replace_all, conflict_target: [:device_id, :key_id])
  end

  @doc """
  Store one-time prekeys.
  """
  def store_one_time_prekeys(device_id, prekeys) when is_list(prekeys) do
    entries =
      Enum.map(prekeys, fn %{"key_id" => key_id, "public_key" => public_key} ->
        %{
          id: Ecto.UUID.generate(),
          device_id: device_id,
          key_id: key_id,
          public_key: Base.decode64!(public_key),
          used: false,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        }
      end)

    {count, _} = Repo.insert_all(Chat.Encryption.OneTimePrekey, entries, on_conflict: :nothing)
    {:ok, count}
  end

  @doc """
  Count available (unused) one-time prekeys for a device.
  """
  def count_available_prekeys(device_id) do
    Repo.one(
      from p in Chat.Encryption.OneTimePrekey,
      where: p.device_id == ^device_id and p.used == false,
      select: count()
    )
  end

  @doc """
  Get prekey bundle for initiating session.
  Returns: identity key, signed prekey, and one one-time prekey (marks it as used).
  """
  def get_prekey_bundle(device_id) do
    Repo.transaction(fn ->
      # Get identity key
      identity_key = Repo.get_by(Chat.Encryption.IdentityKey, device_id: device_id)

      unless identity_key do
        Repo.rollback(:no_identity_key)
      end

      # Get latest signed prekey
      signed_prekey =
        Repo.one(
          from p in Chat.Encryption.SignedPrekey,
          where: p.device_id == ^device_id,
          order_by: [desc: p.inserted_at],
          limit: 1
        )

      unless signed_prekey do
        Repo.rollback(:no_signed_prekey)
      end

      # Get and mark one one-time prekey as used
      one_time_prekey =
        Repo.one(
          from p in Chat.Encryption.OneTimePrekey,
          where: p.device_id == ^device_id and p.used == false,
          order_by: [asc: p.inserted_at],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )

      if one_time_prekey do
        one_time_prekey
        |> Ecto.Changeset.change(used: true)
        |> Repo.update!()
      end

      # Build bundle
      %{
        device_id: device_id,
        identity_key: Base.encode64(identity_key.identity_public_key),
        signed_prekey: %{
          key_id: signed_prekey.key_id,
          public_key: Base.encode64(signed_prekey.public_key),
          signature: Base.encode64(signed_prekey.signature)
        },
        one_time_prekey:
          if one_time_prekey do
            %{
              key_id: one_time_prekey.key_id,
              public_key: Base.encode64(one_time_prekey.public_key)
            }
          else
            nil
          end
      }
    end)
  end
end
