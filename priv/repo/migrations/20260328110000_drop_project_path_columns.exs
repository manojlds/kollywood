defmodule Kollywood.Repo.Migrations.DropProjectPathColumns do
  use Ecto.Migration

  def change do
    alter table(:projects) do
      remove(:local_path)
      remove(:workflow_path)
    end
  end
end
