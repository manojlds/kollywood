defmodule Kollywood.Repo.Migrations.CreateOrchestratorEphemeralEntries do
  use Ecto.Migration

  def change do
    create table(:orchestrator_ephemeral_entries, primary_key: false) do
      add(:issue_id, :string, primary_key: true)
      add(:kind, :string, primary_key: true)
      add(:expires_at_ms, :bigint, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:orchestrator_ephemeral_entries, [:expires_at_ms]))
  end
end
