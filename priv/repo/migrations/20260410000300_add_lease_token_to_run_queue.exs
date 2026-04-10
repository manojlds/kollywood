defmodule Kollywood.Repo.Migrations.AddLeaseTokenToRunQueue do
  use Ecto.Migration

  def change do
    alter table(:run_queue) do
      add(:lease_token, :string)
    end

    create(index(:run_queue, [:lease_token]))
    create(index(:run_queue, [:status, :lease_token]))
  end
end
