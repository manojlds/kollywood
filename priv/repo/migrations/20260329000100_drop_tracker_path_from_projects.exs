defmodule Kollywood.Repo.Migrations.DropTrackerPathFromProjects do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove :tracker_path, :string
    end
  end
end
