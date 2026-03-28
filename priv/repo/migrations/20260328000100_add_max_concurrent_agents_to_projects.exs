defmodule Kollywood.Repo.Migrations.AddMaxConcurrentAgentsToProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      add(:max_concurrent_agents, :integer)
    end
  end
end
