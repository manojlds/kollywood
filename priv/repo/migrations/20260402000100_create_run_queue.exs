defmodule Kollywood.Repo.Migrations.CreateRunQueue do
  use Ecto.Migration

  def change do
    create table(:run_queue) do
      add(:issue_id, :string, null: false)
      add(:identifier, :string, null: false)
      add(:project_slug, :string)
      add(:status, :string, null: false, default: "pending")
      add(:priority, :integer, null: false, default: 0)
      add(:attempt, :integer)
      add(:config_snapshot, :text)
      add(:run_opts_snapshot, :text)
      add(:result_payload, :text)
      add(:error, :text)
      add(:claimed_by_node, :string)
      add(:claimed_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:run_queue, [:status]))
    create(index(:run_queue, [:issue_id]))
    create(index(:run_queue, [:status, :priority]))
    create(index(:run_queue, [:claimed_by_node, :status]))
  end
end
