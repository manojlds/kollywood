defmodule Kollywood.Agent.Session do
  @moduledoc """
  Runtime state for a single agent session.
  """

  @type prompt_mode :: :stdin | :argv

  @type t :: %__MODULE__{
          id: integer(),
          adapter: module(),
          workspace_path: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{optional(String.t()) => String.t()},
          timeout_ms: pos_integer(),
          prompt_mode: prompt_mode()
        }

  @enforce_keys [:id, :adapter, :workspace_path, :command, :args, :env, :timeout_ms, :prompt_mode]
  defstruct [:id, :adapter, :workspace_path, :command, :args, :env, :timeout_ms, :prompt_mode]
end
