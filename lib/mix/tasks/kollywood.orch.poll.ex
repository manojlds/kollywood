defmodule Mix.Tasks.Kollywood.Orch.Poll do
  @shortdoc "Trigger one orchestrator poll cycle"

  @moduledoc """
  Triggers a single orchestrator poll cycle immediately.

      mix kollywood.orch.poll
  """

  use Mix.Task

  alias Kollywood.Orchestrator
  alias Mix.Tasks.Kollywood.Orch.Shared

  @impl Mix.Task
  def run(args) do
    {_opts, positional, invalid} = OptionParser.parse(args, strict: [], aliases: [])

    Shared.ensure_no_invalid_options!(invalid)
    Shared.ensure_no_positional_args!(positional)

    server = Shared.ensure_orchestrator_running!()
    :ok = Orchestrator.poll_now(server)
    status = Orchestrator.status(server)

    Mix.shell().info(
      "Poll completed: running=#{status.running_count} retrying=#{status.retry_count} last_error=#{status.last_error || "-"}"
    )
  end
end
