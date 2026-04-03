defmodule Kollywood.Repo.Migrations.AddUniqueActiveIssueIndexToRunQueue do
  use Ecto.Migration

  def change do
    create(
      unique_index(:run_queue, [:issue_id],
        name: :run_queue_active_issue_id_index,
        where: "status IN ('pending', 'claimed', 'running')"
      )
    )
  end
end
