defmodule Kollywood.Repo.Migrations.AddLastHeartbeatAtToRunQueue do
  use Ecto.Migration

  def change do
    alter table(:run_queue) do
      add(:last_heartbeat_at, :utc_datetime_usec)
    end

    create(index(:run_queue, [:status, :last_heartbeat_at]))
  end
end
