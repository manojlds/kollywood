defmodule Mix.Tasks.Kollywood.Orch.Logs do
  @shortdoc "Show persisted run logs for one story"

  @moduledoc """
  Prints persisted run logs for one story attempt.

      mix kollywood.orch.logs STORY_ID
      mix kollywood.orch.logs STORY_ID --attempt 2
      mix kollywood.orch.logs STORY_ID --follow
  """

  use Mix.Task

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Mix.Tasks.Kollywood.Orch.Shared

  @default_follow_poll_ms 200

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [follow: :boolean, attempt: :integer],
        aliases: [f: :follow, a: :attempt]
      )

    Shared.ensure_no_invalid_options!(invalid)

    {story_id, follow?, attempt_selector} = parse_cli_args!(positional, opts)
    project_root = resolve_project_root!()
    attempt = resolve_attempt!(project_root, story_id, attempt_selector)

    print_attempt_header(story_id, attempt)

    offset = print_existing_log(attempt.files.run)

    if follow? do
      follow_log(attempt.files.run, offset)
    end
  end

  defp parse_cli_args!(positional, opts) do
    case positional do
      [story_id] ->
        story_id = String.trim(story_id)

        if story_id == "" do
          Mix.raise("STORY_ID cannot be empty")
        end

        attempt_selector =
          case opts[:attempt] do
            nil -> :latest
            value when is_integer(value) and value > 0 -> value
            value -> Mix.raise("--attempt must be a positive integer (got: #{inspect(value)})")
          end

        {story_id, Keyword.get(opts, :follow, false), attempt_selector}

      _other ->
        Mix.raise("Usage: mix kollywood.orch.logs STORY_ID [--follow] [--attempt N]")
    end
  end

  defp resolve_project_root! do
    workflow_path =
      Application.get_env(:kollywood, :workflow_path, Path.join(File.cwd!(), "WORKFLOW.md"))
      |> Path.expand()

    with {:ok, content} <- File.read(workflow_path),
         {:ok, config, _prompt_template} <- Config.parse(content) do
      RunLogs.project_root(config)
    else
      {:error, reason} ->
        Mix.raise("Failed to resolve workflow config from #{workflow_path}: #{reason}")
    end
  end

  defp resolve_attempt!(project_root, story_id, attempt_selector) do
    case RunLogs.resolve_attempt(project_root, story_id, attempt_selector) do
      {:ok, attempt} ->
        attempt

      {:error, reason} ->
        Mix.raise(reason)
    end
  end

  defp print_attempt_header(story_id, attempt) do
    metadata = attempt.metadata

    Mix.shell().info(
      "Run logs for #{story_id} attempt ##{attempt.attempt} status=#{Map.get(metadata, "status", "unknown")}"
    )

    Mix.shell().info("- started_at=#{Map.get(metadata, "started_at", "-")}")
    Mix.shell().info("- ended_at=#{Map.get(metadata, "ended_at", "-")}")
    Mix.shell().info("- path=#{attempt.files.run}")
  end

  defp print_existing_log(path) do
    case File.read(path) do
      {:ok, ""} ->
        Mix.shell().info("(run log is empty)")
        0

      {:ok, content} ->
        IO.write(content)
        byte_size(content)

      {:error, :enoent} ->
        Mix.shell().info("(run log file not found: #{path})")
        0

      {:error, reason} ->
        Mix.raise("Failed to read run log #{path}: #{inspect(reason)}")
    end
  end

  defp follow_log(path, offset) do
    poll_ms =
      case Application.get_env(:kollywood, :orch_logs_follow_poll_ms, @default_follow_poll_ms) do
        value when is_integer(value) and value > 0 -> value
        _other -> @default_follow_poll_ms
      end

    Mix.shell().info("Following #{path} (Ctrl+C to stop)")
    follow_loop(path, offset, poll_ms)
  end

  defp follow_loop(path, offset, poll_ms) do
    Process.sleep(poll_ms)

    case File.read(path) do
      {:ok, content} ->
        size = byte_size(content)

        cond do
          size < offset ->
            IO.write(content)
            follow_loop(path, size, poll_ms)

          size > offset ->
            chunk = binary_part(content, offset, size - offset)
            IO.write(chunk)
            follow_loop(path, size, poll_ms)

          true ->
            follow_loop(path, offset, poll_ms)
        end

      {:error, :enoent} ->
        follow_loop(path, 0, poll_ms)

      {:error, _reason} ->
        follow_loop(path, offset, poll_ms)
    end
  end
end
