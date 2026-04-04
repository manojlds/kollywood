defmodule Kollywood.Repo.Migrations.CreateRuntimeSessions do
  use Ecto.Migration

  def change do
    create table(:runtime_sessions, primary_key: false) do
      add(:project_slug, :string, primary_key: true)
      add(:story_id, :string, primary_key: true)
      add(:status, :string, null: false, default: "running")
      add(:session_type, :string, null: false, default: "testing")
      add(:runtime_kind, :string, null: false)
      add(:runtime_state_term, :binary, null: false)
      add(:preview_url, :text)
      add(:resolved_ports_json, :text)
      add(:workspace_path, :text)
      add(:started_at, :utc_datetime_usec)
      add(:expires_at, :utc_datetime_usec)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:runtime_sessions, [:status]))
    create(index(:runtime_sessions, [:session_type]))
    create(index(:runtime_sessions, [:expires_at]))
  end
end
