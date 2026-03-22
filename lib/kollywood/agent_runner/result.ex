defmodule Kollywood.AgentRunner.Result do
  @moduledoc """
  Final outcome for one issue run through the agent runner.
  """

  @type status :: :ok | :failed | :max_turns_reached

  @type event :: %{
          required(:type) => atom(),
          required(:timestamp) => DateTime.t(),
          optional(atom()) => any()
        }

  @type t :: %__MODULE__{
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          workspace_path: String.t() | nil,
          turn_count: non_neg_integer(),
          status: status(),
          started_at: DateTime.t(),
          ended_at: DateTime.t(),
          last_output: String.t() | nil,
          events: [event()],
          error: String.t() | nil
        }

  defstruct [
    :issue_id,
    :identifier,
    :workspace_path,
    :status,
    :started_at,
    :ended_at,
    :last_output,
    :error,
    turn_count: 0,
    events: []
  ]
end
