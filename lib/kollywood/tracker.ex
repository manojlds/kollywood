defmodule Kollywood.Tracker do
  @moduledoc """
  Behaviour for tracker adapters used by the orchestrator.

  Stage 5 uses this read-only interface to fetch currently active issues.
  Stage 6 will add concrete adapters for Linear, GitHub Issues, Jira, and PRD files.
  """

  alias Kollywood.Config

  @type issue :: map()

  @callback list_active_issues(Config.t()) :: {:ok, [issue()]} | {:error, String.t()}
end
