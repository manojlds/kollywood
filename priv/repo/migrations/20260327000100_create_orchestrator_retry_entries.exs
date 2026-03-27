defmodule Kollywood.Repo.Migrations.CreateOrchestratorRetryEntries do
  use Ecto.Migration

  def change do
    create table(:orchestrator_retry_entries, primary_key: false) do
      add(:issue_id, :string, primary_key: true)
      add(:attempt, :integer, null: false)
      add(:reason, :text)
      add(:kind, :string, null: false, default: "run")
      add(:due_at_ms, :bigint, null: false)
      add(:issue_term, :binary, null: false)
      add(:finalization_term, :binary)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:orchestrator_retry_entries, [:updated_at]))
  end
end
