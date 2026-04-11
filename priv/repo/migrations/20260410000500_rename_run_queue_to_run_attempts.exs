defmodule Kollywood.Repo.Migrations.RenameRunQueueToRunAttempts do
  use Ecto.Migration

  def change do
    rename(table(:run_queue), to: table(:run_attempts))
  end
end
