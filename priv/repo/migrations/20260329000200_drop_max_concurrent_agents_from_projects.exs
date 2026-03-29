defmodule Kollywood.Repo.Migrations.DropMaxConcurrentAgentsFromProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove :max_concurrent_agents, :integer
    end
  end
end
