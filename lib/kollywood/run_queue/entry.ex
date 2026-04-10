defmodule Kollywood.RunQueue.Entry do
  @moduledoc """
  Ecto schema for a run queue entry.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ["pending", "claimed", "running", "completed", "failed", "cancelled"]

  schema "run_queue" do
    field(:issue_id, :string)
    field(:identifier, :string)
    field(:project_slug, :string)
    field(:status, :string, default: "pending")
    field(:priority, :integer, default: 0)
    field(:attempt, :integer)
    field(:config_snapshot, :string)
    field(:run_opts_snapshot, :string)
    field(:result_payload, :string)
    field(:error, :string)
    field(:claimed_by_node, :string)
    field(:claimed_at, :utc_datetime_usec)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:issue_id, :identifier, :status]
  @optional_fields [
    :project_slug,
    :priority,
    :attempt,
    :config_snapshot,
    :run_opts_snapshot,
    :result_payload,
    :error,
    :claimed_by_node,
    :claimed_at,
    :last_heartbeat_at,
    :started_at,
    :completed_at
  ]

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
