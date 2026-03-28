defmodule Mix.Tasks.Kollywood.Orch.Maintenance do
  @shortdoc "Manage orchestrator maintenance/drain mode"

  @moduledoc """
  Manages orchestrator maintenance mode via control files.

      mix kollywood.orch.maintenance
      mix kollywood.orch.maintenance --mode drain
      mix kollywood.orch.maintenance --mode drain --wait --timeout 600
      mix kollywood.orch.maintenance --mode normal
  """

  use Mix.Task

  alias Kollywood.Orchestrator.ControlState
  alias Mix.Tasks.Kollywood.Orch.Shared

  @default_wait_timeout_seconds 600
  @default_wait_interval_ms 1_000

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [mode: :string, wait: :boolean, timeout: :integer, interval: :integer],
        aliases: [m: :mode, w: :wait, t: :timeout, i: :interval]
      )

    Shared.ensure_no_invalid_options!(invalid)
    Shared.ensure_no_positional_args!(positional)

    mode_arg = Keyword.get(opts, :mode)
    wait? = Keyword.get(opts, :wait, false)
    timeout_seconds = positive_integer(Keyword.get(opts, :timeout), @default_wait_timeout_seconds)
    interval_ms = positive_integer(Keyword.get(opts, :interval), @default_wait_interval_ms)

    if wait? and mode_arg not in ["drain", :drain] do
      Mix.raise("--wait requires --mode drain")
    end

    if mode_arg do
      mode = parse_mode!(mode_arg)

      case ControlState.write_maintenance_mode(mode, source: "mix:kollywood.orch.maintenance") do
        :ok ->
          Mix.shell().info("Maintenance mode set to #{mode}")

        {:error, reason} ->
          Mix.raise(reason)
      end
    end

    case ControlState.read_maintenance_mode() do
      {:ok, mode} ->
        Mix.shell().info("Current maintenance mode: #{mode}")

      {:error, reason} ->
        Mix.raise(reason)
    end

    if wait? do
      wait_for_drain!(timeout_seconds, interval_ms)
    end

    print_status_path()
  end

  defp parse_mode!(mode) do
    case ControlState.parse_mode(mode) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp wait_for_drain!(timeout_seconds, interval_ms) do
    timeout_ms = timeout_seconds * 1_000
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    Mix.shell().info(
      "Waiting for orchestrator drain (timeout=#{timeout_seconds}s interval=#{interval_ms}ms)"
    )

    case wait_for_drain_until(deadline_ms, interval_ms) do
      {:ok, running_count} ->
        Mix.shell().info("Drain complete (running=#{running_count})")

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp wait_for_drain_until(deadline_ms, interval_ms) do
    case read_running_count() do
      {:ok, running_count} when running_count == 0 ->
        {:ok, running_count}

      {:ok, running_count} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, "Drain timed out with running=#{running_count}"}
        else
          Process.sleep(interval_ms)
          wait_for_drain_until(deadline_ms, interval_ms)
        end

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= deadline_ms do
          {:error, "Drain timed out: #{reason}"}
        else
          Process.sleep(interval_ms)
          wait_for_drain_until(deadline_ms, interval_ms)
        end
    end
  end

  defp read_running_count do
    with {:ok, status} <- ControlState.read_status(),
         maintenance_mode when maintenance_mode in ["drain", :drain] <-
           Map.get(status, "maintenance_mode") || Map.get(status, :maintenance_mode),
         running_count <- Map.get(status, "running_count") || Map.get(status, :running_count),
         {:ok, running_count} <- parse_running_count(running_count) do
      {:ok, running_count}
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "maintenance status unavailable: #{inspect(other)}"}
    end
  end

  defp parse_running_count(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_running_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> {:ok, parsed}
      _other -> {:error, "invalid running_count in status file: #{inspect(value)}"}
    end
  end

  defp parse_running_count(value),
    do: {:error, "invalid running_count in status file: #{inspect(value)}"}

  defp print_status_path do
    Mix.shell().info("Status file: #{ControlState.status_path()}")
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp positive_integer(_value, default), do: default
end
