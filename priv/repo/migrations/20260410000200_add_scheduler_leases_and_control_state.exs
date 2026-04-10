defmodule Kollywood.Repo.Migrations.AddSchedulerLeasesAndControlState do
  use Ecto.Migration

  def change do
    create table(:scheduler_leases, primary_key: false) do
      add(:name, :string, primary_key: true)
      add(:owner_id, :string)
      add(:lease_expires_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:scheduler_leases, [:lease_expires_at]))

    create table(:orchestrator_control_states, primary_key: false) do
      add(:key, :string, primary_key: true)
      add(:value_json, :text)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
