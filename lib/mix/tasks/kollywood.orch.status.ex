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
      "- maintenance_mode=#{status.maintenance_mode} dispatch_paused=#{status.dispatch_paused} drain_ready=#{status.drain_ready}"
    )

    Mix.shell().info(
      "- poll_interval_ms=#{status.poll_interval_ms} max_concurrent_agents_requested=#{status.max_concurrent_agents_requested} max_concurrent_agents_effective=#{status.max_concurrent_agents_effective} max_concurrent_agents_hard_cap=#{status.max_concurrent_agents_hard_cap} retries_enabled=#{status.retries_enabled}"
    )

    Mix.shell().info("- last_poll_at=#{Shared.format_datetime(status.last_poll_at)}")
    Mix.shell().info("- last_error=#{status.last_error || "-"}")

    watchdog = Map.get(status, :watchdog, %{})

    Mix.shell().info(
      "- poll_stale=#{Map.get(watchdog, :stale, false)} poll_age_ms=#{format_integer(Map.get(watchdog, :age_ms))} stale_threshold_ms=#{format_integer(Map.get(watchdog, :threshold_ms))}"
    )

    Mix.shell().info(
      "- watchdog_check_interval_ms=#{format_integer(Map.get(watchdog, :check_interval_ms))} stale_threshold_multiplier=#{format_integer(Map.get(watchdog, :stale_threshold_multiplier))}"
    )

    case Map.get(watchdog, :last_recovery_attempt) do
      nil ->
        Mix.shell().info("- last_recovery_attempt=none")

      attempt when is_map(attempt) ->
        Mix.shell().info(
          "- last_recovery_attempt_at=#{Shared.format_datetime(Map.get(attempt, :attempted_at))} outcome=#{Map.get(attempt, :outcome) || "-"} stale_age_ms=#{format_integer(Map.get(attempt, :stale_age_ms))} post_recovery_age_ms=#{format_integer(Map.get(attempt, :post_recovery_age_ms))}"
        )
    end

    print_running(status.running)
    print_retrying(status.retrying)
  end

  defp format_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp format_integer(_value), do: "-"

  defp print_running([]) do
    Mix.shell().info("- running_issues: none")
  end

  defp print_running(running) do
    Mix.shell().info("- running_issues:")

    Enum.each(running, fn item ->
      Mix.shell().info(
        "  #{item.issue_id} (#{item.identifier || "-"}) attempt=#{inspect(item.attempt)} started_at=#{Shared.format_datetime(item.started_at)} runtime_profile=#{item.runtime_profile} runtime_state=#{item.runtime_process_state} runtime_event=#{item.runtime_last_event_type || "-"}"
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
