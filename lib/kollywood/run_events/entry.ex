defmodule Kollywood.RunEvents.Entry do
  @moduledoc """
  Ecto schema for structured run-event persistence.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "run_event_entries" do
    field(:project_slug, :string)
    field(:story_id, :string)
    field(:attempt, :integer)
    field(:seq, :integer)
    field(:event_type, :string)
    field(:category, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:turn, :integer)
    field(:cycle, :integer)
    field(:run_state_json, :string)
    field(:payload_json, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :project_slug,
    :story_id,
    :attempt,
    :seq,
    :event_type,
    :category,
    :occurred_at,
    :payload_json
  ]

  @optional_fields [:turn, :cycle, :run_state_json]

  @type t :: %__MODULE__{}

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:seq, greater_than: 0)
    |> validate_length(:project_slug, min: 1)
    |> validate_length(:story_id, min: 1)
    |> validate_length(:event_type, min: 1)
    |> validate_length(:category, min: 1)
    |> validate_length(:payload_json, min: 1)
    |> unique_constraint(:seq, name: :run_event_entries_stream_seq_index)
  end
end
