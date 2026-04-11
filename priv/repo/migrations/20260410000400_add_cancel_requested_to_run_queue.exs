defmodule Kollywood.Repo.Migrations.AddCancelRequestedToRunQueue do
  use Ecto.Migration

  def change do
    alter table(:run_queue) do
      add(:cancel_requested_at, :utc_datetime_usec)
      add(:cancel_reason, :text)
    end

    drop_if_exists(index(:run_queue, [:issue_id], name: :run_queue_active_issue_id_index))

    create(
      unique_index(:run_queue, [:issue_id],
        name: :run_queue_active_issue_id_index,
        where: "status IN ('pending', 'claimed', 'running', 'cancel_requested')"
      )
    )

    create(index(:run_queue, [:status, :cancel_requested_at]))
  end
end
