defmodule Mix.Tasks.Kollywood.Orch.Stop do
  @shortdoc "Stop one running/retrying issue"

  @moduledoc """
  Stops one issue if it is currently running or queued for retry.

      mix kollywood.orch.stop ISSUE_ID
  """

  use Mix.Task

  alias Kollywood.Orchestrator
  alias Mix.Tasks.Kollywood.Orch.Shared

  @impl Mix.Task
  def run(args) do
    {_opts, positional, invalid} = OptionParser.parse(args, strict: [], aliases: [])

    Shared.ensure_no_invalid_options!(invalid)

    issue_id =
      case positional do
        [value] ->
          trimmed = String.trim(value)

          if trimmed == "" do
            Mix.raise("ISSUE_ID cannot be empty")
          else
            trimmed
          end

        [] ->
          Mix.raise("Usage: mix kollywood.orch.stop ISSUE_ID")

        _other ->
          Mix.raise("Usage: mix kollywood.orch.stop ISSUE_ID")
      end

    server = Shared.ensure_orchestrator_running!()
    :ok = Orchestrator.stop_issue(server, issue_id)

    Mix.shell().info("Requested stop for issue #{issue_id}")
  end
end
