defmodule Mix.Tasks.Kollywood.Orch.Status do
  @shortdoc "Show orchestrator runtime status"

  @moduledoc """
  Prints the current orchestrator runtime snapshot.

      mix kollywood.orch.status
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
    status = Orchestrator.status(server)

    Mix.shell().info("Orchestrator status")

    Mix.shell().info(
      "- running=#{status.running_count} retrying=#{status.retry_count} claimed=#{status.claimed_count} completed=#{status.completed_count}"
    )

    Mix.shell().info(
      "- poll_interval_ms=#{status.poll_interval_ms} max_concurrent_agents=#{status.max_concurrent_agents} retries_enabled=#{status.retries_enabled}"
    )

    Mix.shell().info("- last_poll_at=#{Shared.format_datetime(status.last_poll_at)}")
    Mix.shell().info("- last_error=#{status.last_error || "-"}")

    print_running(status.running)
    print_retrying(status.retrying)
  end

  defp print_running([]) do
    Mix.shell().info("- running_issues: none")
  end

  defp print_running(running) do
    Mix.shell().info("- running_issues:")

    Enum.each(running, fn item ->
      Mix.shell().info(
        "  #{item.issue_id} (#{item.identifier || "-"}) attempt=#{inspect(item.attempt)} started_at=#{Shared.format_datetime(item.started_at)}"
      )
    end)
  end

  defp print_retrying([]) do
    Mix.shell().info("- retry_queue: none")
  end

  defp print_retrying(retrying) do
    Mix.shell().info("- retry_queue:")

    Enum.each(retrying, fn item ->
      Mix.shell().info(
        "  #{item.issue_id} (#{item.identifier || "-"}) attempt=#{item.attempt} due_in_ms=#{item.due_in_ms} reason=#{item.reason || "-"}"
      )
    end)
  end
end
