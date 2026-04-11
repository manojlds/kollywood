defmodule Kollywood.RunAttempts.Attempt do
  @moduledoc """
  Ecto schema for a durable run attempt.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses [
    "pending",
    "claimed",
    "running",
    "cancel_requested",
    "completed",
    "failed",
    "cancelled"
  ]

  schema "run_attempts" do
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
    field(:lease_token, :string)
    field(:claimed_at, :utc_datetime_usec)
    field(:last_heartbeat_at, :utc_datetime_usec)
    field(:cancel_requested_at, :utc_datetime_usec)
    field(:cancel_reason, :string)
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
    :lease_token,
    :claimed_at,
    :last_heartbeat_at,
    :cancel_requested_at,
    :cancel_reason,
    :started_at,
    :completed_at
  ]

  @type t :: %__MODULE__{}

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
