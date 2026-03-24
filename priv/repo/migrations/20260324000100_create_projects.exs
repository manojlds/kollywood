defmodule Kollywood.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add(:name, :string, null: false)
      add(:slug, :string, null: false)
      add(:provider, :string, null: false)
      add(:repository, :string)
      add(:local_path, :string)
      add(:default_branch, :string, null: false, default: "main")
      add(:workflow_path, :string)
      add(:tracker_path, :string)
      add(:enabled, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:projects, [:slug]))
  end
end
