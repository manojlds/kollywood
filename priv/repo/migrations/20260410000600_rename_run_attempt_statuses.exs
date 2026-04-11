defmodule Kollywood.Repo.Migrations.RenameRunAttemptStatuses do
  use Ecto.Migration

  def up do
    execute("UPDATE run_attempts SET status = 'queued' WHERE status = 'pending'")
    execute("UPDATE run_attempts SET status = 'leased' WHERE status = 'claimed'")

    drop_if_exists(index(:run_attempts, [:issue_id], name: :run_queue_active_issue_id_index))
    drop_if_exists(index(:run_attempts, [:issue_id], name: :run_attempts_active_issue_id_index))

    create(
      unique_index(:run_attempts, [:issue_id],
        name: :run_attempts_active_issue_id_index,
        where: "status IN ('queued', 'leased', 'running', 'cancel_requested')"
      )
    )
  end

  def down do
    execute("UPDATE run_attempts SET status = 'pending' WHERE status = 'queued'")
    execute("UPDATE run_attempts SET status = 'claimed' WHERE status = 'leased'")

    drop_if_exists(index(:run_attempts, [:issue_id], name: :run_attempts_active_issue_id_index))

    create(
      unique_index(:run_attempts, [:issue_id],
        name: :run_queue_active_issue_id_index,
        where: "status IN ('pending', 'claimed', 'running', 'cancel_requested')"
      )
    )
  end
end
