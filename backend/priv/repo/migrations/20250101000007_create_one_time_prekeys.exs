defmodule Chat.Repo.Migrations.CreateOneTimePrekeys do
  use Ecto.Migration

  def change do
    create table(:one_time_prekeys, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :device_id, references(:devices, type: :uuid, on_delete: :delete_all), null: false
      add :key_id, :integer, null: false
      add :public_key, :bytea, null: false
      add :used, :boolean, default: false, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:one_time_prekeys, [:device_id])

    # Critical index for prekey bundle fetching - find unused keys quickly
    create index(:one_time_prekeys, [:device_id, :used],
      where: "used = false",
      name: :one_time_prekeys_unused_idx
    )

    create unique_index(:one_time_prekeys, [:device_id, :key_id])
  end
end
