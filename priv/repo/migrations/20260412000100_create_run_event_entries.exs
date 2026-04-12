defmodule Kollywood.Repo.Migrations.CreateRunEventEntries do
  use Ecto.Migration

  def change do
    create table(:run_event_entries) do
      add(:project_slug, :string, null: false)
      add(:story_id, :string, null: false)
      add(:attempt, :integer, null: false)
      add(:seq, :integer, null: false)
      add(:event_type, :string, null: false)
      add(:category, :string, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:turn, :integer)
      add(:cycle, :integer)
      add(:run_state_json, :text)
      add(:payload_json, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:run_event_entries, [:project_slug, :story_id, :attempt, :seq],
        name: :run_event_entries_stream_seq_index
      )
    )

    create(index(:run_event_entries, [:project_slug, :story_id, :attempt, :occurred_at]))
    create(index(:run_event_entries, [:project_slug, :story_id, :attempt, :event_type]))
  end
end
