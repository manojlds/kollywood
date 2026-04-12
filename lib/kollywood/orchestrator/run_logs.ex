defmodule Kollywood.Orchestrator.RunLogs do
  @moduledoc """
  Persists per-story run attempt metadata and append-only logs.

  Log layout:

      <project_data_root>/run_logs/<story_id>/
        attempts.jsonl
        attempt-0001/
          metadata.json
          events.jsonl
          run.log
          worker.log
          reviewer.log
          tester.log
          checks.log
          runtime.log
          testing_report.json
          testing_artifacts/

  `run.log` is a merged stream, while category files keep focused slices for
  worker/reviewer/check/runtime output.
  """

  require Logger

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunState
  alias Kollywood.RecoveryGuidance
  alias Kollywood.ServiceConfig

  @base_log_dir ["run_logs"]

  @worker_events [
    "run_started",
    "workspace_ready",
    "execution_session_started",
    "execution_session_completed",
    "execution_session_stopped",
    "execution_session_stop_failed",
    "session_started",
    "turn_started",
    "turn_succeeded",
    "turn_failed",
    "completion_detected",
    "idle_timeout_reached",
    "session_stopped",
    "session_stop_failed",
    "quality_cycle_started",
    "quality_cycle_passed",
    "quality_cycle_retrying",
    "run_finished"
  ]

  @review_events [
    "review_started",
    "review_passed",
    "review_failed",
    "review_error"
  ]

  @testing_events [
    "testing_started",
    "testing_checkpoint",
    "testing_passed",
    "testing_failed",
    "testing_error"
  ]

  @checks_events [
    "checks_started",
    "check_started",
    "check_passed",
    "check_failed",
    "checks_passed",
    "checks_failed"
  ]

  @runtime_events [
    "runtime_starting",
    "runtime_started",
    "runtime_start_failed",
    "runtime_healthcheck_started",
    "runtime_healthcheck_passed",
    "runtime_healthcheck_failed",
    "runtime_stopping",
    "runtime_stopped",
    "runtime_stop_failed",
    "workspace_cleanup_deleted",
    "workspace_cleanup_preserved"
  ]

  @agent_log_events [
    "turn_succeeded",
    "review_passed",
    "review_failed",
    "testing_passed",
    "testing_failed"
  ]

  @step_events_path "step_events.jsonl"
  @steps_dir_name "steps"

  @step_event_buckets [
    {:agent,
     [
       "turn_started",
       "turn_succeeded",
       "turn_failed",
       "completion_detected",
       "idle_timeout_reached"
     ]},
    {:checks,
     [
       "checks_started",
       "check_started",
       "check_passed",
       "check_failed",
       "checks_passed",
       "checks_failed"
     ]},
    {:review, ["review_started", "review_passed", "review_failed", "review_error"]},
    {:testing,
     [
       "testing_started",
       "testing_checkpoint",
       "testing_passed",
       "testing_failed",
       "testing_error"
     ]},
    {:runtime,
     [
       "runtime_starting",
       "runtime_started",
       "runtime_start_failed",
       "runtime_healthcheck_started",
       "runtime_healthcheck_passed",
       "runtime_healthcheck_failed",
       "runtime_stopping",
       "runtime_stopped",
       "runtime_stop_failed"
     ]},
    {:publish,
     [
       "publish_started",
       "publish_pending_merge",
       "publish_succeeded",
       "publish_failed",
       "publish_skipped",
       "publish_pr_created",
       "publish_merge_conflict",
       "publish_merge_conflict_resolved",
       "publish_push_succeeded",
       "publish_pr_merge_auto_enabled",
       "publish_pr_merge_auto_failed",
       "publish_pr_create_failed",
       "publish_push_failed",
       "publish_merged",
       "publish_pr_closed"
     ]},
    {:run,
     [
       "run_started",
       "workspace_ready",
       "quality_cycle_started",
       "quality_cycle_retrying",
       "quality_cycle_passed",
       "run_finished"
     ]}
  ]

  @step_start_events %{
    agent: MapSet.new(["turn_started"]),
    checks: MapSet.new(["checks_started"]),
    review: MapSet.new(["review_started"]),
    testing: MapSet.new(["testing_started"]),
    runtime: MapSet.new(["runtime_starting", "runtime_stopping"]),
    publish: MapSet.new(["publish_started"]),
    run: MapSet.new(["run_started"])
  }

  @typedoc "Run-log context returned by `prepare_attempt/3`"
  @type context :: %{
          project_root: String.t(),
          story_id: String.t(),
          issue_id: String.t() | nil,
          identifier: String.t() | nil,
          attempt: pos_integer(),
          runner_attempt: non_neg_integer() | nil,
          attempt_dir: String.t(),
          files: map(),
          retry_mode: String.t(),
          retry_provenance: map()
        }

  @doc "Resolves the project data root used for run-log persistence."
  @spec project_root(Config.t()) :: String.t()
  def project_root(%Config{} = config) do
    slug = project_slug(config) || inferred_project_slug(config)
    ServiceConfig.project_data_dir(slug)
  end

  defp project_slug(%Config{} = config) do
    config
    |> get_in([Access.key(:tracker, %{}), Access.key(:project_slug)])
    |> optional_string()
  end

  defp inferred_project_slug(%Config{} = config) do
    basis = inferred_project_slug_basis(config)

    hash =
      :sha256
      |> :crypto.hash(basis)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    "adhoc-#{hash}"
  end

  defp inferred_project_slug_basis(%Config{} = config) do
    source =
      config
      |> get_in([Access.key(:workspace, %{}), Access.key(:source)])
      |> optional_string()

    tracker_path =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:path)])
      |> optional_string()

    workspace_root =
      config
      |> get_in([Access.key(:workspace, %{}), Access.key(:root)])
      |> optional_string()

    cond do
      source -> "source:" <> expand_path(source)
      tracker_path -> "tracker:" <> expand_path(tracker_path)
      workspace_root -> "workspace:" <> expand_path(workspace_root)
      true -> "cwd:" <> File.cwd!()
    end
  end

  @doc "Creates a new per-attempt run-log directory and metadata file."
  @spec prepare_attempt(Config.t(), map(), non_neg_integer() | nil) ::
          {:ok, context()} | {:error, String.t()}
  def prepare_attempt(%Config{} = config, issue, runner_attempt) when is_map(issue) do
    prepare_attempt(config, issue, runner_attempt, [])
  end

  def prepare_attempt(_config, _issue, _runner_attempt) do
    {:error, "failed to initialize run logs: invalid inputs"}
  end

  @spec prepare_attempt(Config.t(), map(), non_neg_integer() | nil, keyword() | map()) ::
          {:ok, context()} | {:error, String.t()}
  def prepare_attempt(%Config{} = config, issue, runner_attempt, opts)
      when is_map(issue) do
    {retry_mode, retry_provenance, metadata_overrides} = parse_prepare_attempt_opts(opts)

    identifier = field(issue, :identifier)
    issue_id = field(issue, :id)

    story_id =
      identifier
      |> optional_string()
      |> Kernel.||(optional_string(issue_id))
      |> Kernel.||("unknown-story")

    project_root = project_root(config)
    story_dir = story_dir(project_root, story_id)

    with :ok <- File.mkdir_p(story_dir),
         attempt <- next_attempt_number(story_dir),
         attempt_dir <- attempt_dir(story_dir, attempt),
         :ok <- File.mkdir_p(attempt_dir) do
      files = build_attempt_files(story_dir, attempt_dir)

      metadata =
        initial_metadata(
          story_id,
          issue_id,
          identifier,
          attempt,
          runner_attempt,
          project_root,
          attempt_dir,
          files,
          retry_mode,
          retry_provenance,
          metadata_overrides
        )

      with :ok <- ensure_append_files(files),
           :ok <- write_json(files.metadata, metadata),
           :ok <-
             append_jsonl(files.attempts_index, %{
               "event" => "attempt_started",
               "story_id" => story_id,
               "attempt" => attempt,
               "runner_attempt" => runner_attempt,
               "timestamp" => now_iso8601(),
               "attempt_dir" => attempt_dir,
               "parent_attempt" => Map.get(metadata, "parent_attempt"),
               "retry_step" => Map.get(metadata, "retry_step"),
               "retry_mode" => retry_mode,
               "retry_provenance" => retry_provenance
             }) do
        {:ok,
         %{
           project_root: project_root,
           story_id: story_id,
           issue_id: optional_string(issue_id),
           identifier: optional_string(identifier),
           attempt: attempt,
           runner_attempt: runner_attempt,
           attempt_dir: attempt_dir,
           files: files,
           retry_mode: retry_mode,
           retry_provenance: retry_provenance
         }}
      end
    else
      {:error, reason} -> {:error, "failed to initialize run logs: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to initialize run logs: #{Exception.message(error)}"}
  end

  def prepare_attempt(_config, _issue, _runner_attempt, _opts) do
    {:error, "failed to initialize run logs: invalid inputs"}
  end

  @doc "Appends one structured event and a human-readable line to run logs."
  @spec append_event(context(), map()) :: :ok | {:error, String.t()}
  def append_event(%{files: files} = context, event) when is_map(event) do
    normalized_event = normalize_event(event, context)
    category = category_for_event(Map.get(normalized_event, "type"))
    human_line = format_human_line(normalized_event, category)

    with :ok <- append_jsonl(files.events, normalized_event),
         :ok <- append_text(files.run, human_line),
         :ok <- append_text(category_path(files, category), human_line),
         :ok <- maybe_append_agent_log(files, normalized_event),
         :ok <- append_step_event(context, normalized_event, human_line, category) do
      :ok
    else
      {:error, reason} -> {:error, "failed to append run log event: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to append run log event: #{Exception.message(error)}"}
  end

  def append_event(_context, _event), do: :ok

  @doc "Completes a run attempt with final metadata from `%Result{}`."
  @spec complete_attempt(context(), Result.t()) :: :ok | {:error, String.t()}
  def complete_attempt(context, %Result{} = result) do
    base_update = %{
      status: result.status,
      ended_at: result.ended_at,
      turn_count: result.turn_count,
      workspace_path: result.workspace_path,
      error: result.error
    }

    update =
      base_update
      |> maybe_put_last_successful_turn(result.events)
      |> maybe_put_recovery_guidance(result.events, result.error)

    complete_attempt(context, update)
  end

  @spec complete_attempt(context(), map()) :: :ok | {:error, String.t()}
  def complete_attempt(%{files: files} = context, attrs) when is_map(attrs) do
    update =
      attrs
      |> stringify_map()
      |> Map.put_new("ended_at", now_iso8601())
      |> Map.update("status", "finished", &normalize_status_value/1)

    metadata =
      files.metadata
      |> read_json_file()
      |> Map.merge(update)
      |> Map.put("run_state", completion_run_state(update, files))
      |> Map.merge(testing_report_metadata(files))

    with :ok <- write_json(files.metadata, metadata),
         :ok <-
           append_jsonl(files.attempts_index, %{
             "event" => "attempt_finished",
             "story_id" => context.story_id,
             "attempt" => context.attempt,
             "runner_attempt" => context.runner_attempt,
             "timestamp" => now_iso8601(),
             "status" => Map.get(metadata, "status"),
             "error" => Map.get(metadata, "error"),
             "retry_mode" => Map.get(metadata, "retry_mode", "full_rerun"),
             "retry_provenance" => Map.get(metadata, "retry_provenance", %{})
           }) do
      :ok
    else
      {:error, reason} -> {:error, "failed to complete run log metadata: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "failed to complete run log metadata: #{Exception.message(error)}"}
  end

  def complete_attempt(_context, _attrs), do: :ok

  @doc "Returns run-log metadata for tracker/UI surfaces."
  @spec tracker_metadata(context()) :: map()
  def tracker_metadata(%{attempt: attempt, attempt_dir: attempt_dir, files: files} = context) do
    retry_mode = normalize_retry_mode(Map.get(context, :retry_mode, "full_rerun"))
    retry_provenance = normalize_retry_provenance(Map.get(context, :retry_provenance, %{}))

    %{
      retry_mode: retry_mode,
      retry_provenance: retry_provenance,
      run_logs: %{
        attempt: attempt,
        dir: attempt_dir,
        retry_mode: retry_mode,
        retry_provenance: retry_provenance,
        files: %{
          run: files.run,
          worker: files.worker,
          reviewer: files.reviewer,
          tester: files.tester,
          checks: files.checks,
          runtime: files.runtime,
          events: files.events,
          metadata: files.metadata,
          agent: files.agent,
          agent_stdout: files.agent_stdout,
          reviewer_stdout: files.reviewer_stdout,
          tester_stdout: files.tester_stdout,
          review_json: files.review_json,
          review_cycles_dir: files.review_cycles_dir,
          testing_json: files.testing_json,
          testing_cycles_dir: files.testing_cycles_dir,
          testing_report: files.testing_report,
          testing_artifacts_dir: files.testing_artifacts_dir,
          steps_dir: files.steps_dir,
          step_events: files.step_events
        }
      }
    }
  end

  @doc """
  Extracts the immutable settings snapshot from attempt metadata.

  Returns `nil` for legacy attempts that predate settings snapshots.
  """
  @spec settings_snapshot(map()) :: map() | nil
  def settings_snapshot(%{metadata: metadata}) when is_map(metadata),
    do: settings_snapshot(metadata)

  def settings_snapshot(metadata) when is_map(metadata) do
    case Map.get(metadata, "settings_snapshot") do
      snapshot when is_map(snapshot) -> snapshot
      _other -> nil
    end
  end

  def settings_snapshot(_metadata), do: nil

  @doc "Lists available persisted attempts for a story."
  @spec list_attempts(String.t(), String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def list_attempts(project_root, story_id)
      when is_binary(project_root) and is_binary(story_id) do
    story_dir = story_dir(project_root, story_id)

    case File.ls(story_dir) do
      {:ok, entries} ->
        attempts =
          entries
          |> Enum.map(&parse_attempt_entry/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort()
          |> Enum.map(fn attempt ->
            dir = attempt_dir(story_dir, attempt)
            files = build_attempt_files(story_dir, dir)

            %{
              attempt: attempt,
              dir: dir,
              files: files,
              metadata: read_json_file(files.metadata)
            }
            |> then(fn attempt_entry ->
              Map.put(attempt_entry, :settings_snapshot, settings_snapshot(attempt_entry))
            end)
          end)

        {:ok, attempts}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, "failed to list run logs at #{story_dir}: #{inspect(reason)}"}
    end
  end

  @doc "Resolves one persisted attempt (`:latest` or explicit attempt number)."
  @spec resolve_attempt(String.t(), String.t(), :latest | pos_integer()) ::
          {:ok, map()} | {:error, String.t()}
  def resolve_attempt(project_root, story_id, :latest) do
    with {:ok, attempts} <- list_attempts(project_root, story_id),
         false <- attempts == [] do
      {:ok, List.last(attempts)}
    else
      true -> {:error, "no run logs found for #{story_id}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_attempt(project_root, story_id, attempt)
      when is_integer(attempt) and attempt > 0 do
    with {:ok, attempts} <- list_attempts(project_root, story_id) do
      case Enum.find(attempts, &(&1.attempt == attempt)) do
        nil -> {:error, "attempt #{attempt} not found for #{story_id}"}
        found -> {:ok, found}
      end
    end
  end

  def resolve_attempt(_project_root, _story_id, attempt) do
    {:error, "invalid attempt selector: #{inspect(attempt)}"}
  end

  @doc "Lists events for one attempt after a cursor (1-based line index)."
  @spec list_events(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, %{events: [map()], next_cursor: non_neg_integer(), metadata: map(), files: map()}}
          | {:error, String.t()}
  def list_events(project_root, story_id, attempt, opts \\ [])

  def list_events(project_root, story_id, attempt, opts)
      when is_binary(project_root) and is_binary(story_id) and is_integer(attempt) and attempt > 0 do
    with {:ok, %{metadata: metadata, files: files}} <-
           resolve_attempt(project_root, story_id, attempt),
         {:ok, events, next_cursor} <- read_events_slice(files.events, opts) do
      {:ok,
       %{
         events: events,
         next_cursor: next_cursor,
         metadata: metadata,
         files: files
       }}
    end
  end

  def list_events(_project_root, _story_id, _attempt, _opts) do
    {:error, "invalid event selector"}
  end

  @doc "Marks interrupted step-retry attempts that were left in running state as failed."
  @spec reconcile_orphaned_step_retries(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def reconcile_orphaned_step_retries(project_root, opts \\ [])

  def reconcile_orphaned_step_retries(project_root, opts) when is_binary(project_root) do
    run_logs_root = Path.join([project_root | @base_log_dir])

    reason =
      opts
      |> Keyword.get(:reason)
      |> optional_string()
      |> Kernel.||("step retry interrupted before completion")

    case File.ls(run_logs_root) do
      {:ok, entries} ->
        count =
          entries
          |> Enum.sort()
          |> Enum.reduce(0, fn story_entry, acc ->
            acc + reconcile_story_step_retries(run_logs_root, story_entry, reason)
          end)

        {:ok, count}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, "failed to list run logs at #{run_logs_root}: #{inspect(reason)}"}
    end
  end

  def reconcile_orphaned_step_retries(_project_root, _opts) do
    {:error, "project_root must be a non-empty string"}
  end

  defp reconcile_story_step_retries(run_logs_root, story_entry, reason) do
    story_dir = Path.join(run_logs_root, story_entry)

    if File.dir?(story_dir) do
      File.ls(story_dir)
      |> case do
        {:ok, attempt_entries} ->
          attempt_entries
          |> Enum.sort()
          |> Enum.reduce(0, fn entry, acc ->
            case parse_attempt_entry(entry) do
              attempt when is_integer(attempt) ->
                acc + maybe_reconcile_attempt(story_dir, story_entry, attempt, reason)

              _other ->
                acc
            end
          end)

        {:error, ls_reason} ->
          Logger.warning("failed to list attempt entries at #{story_dir}: #{inspect(ls_reason)}")
          0
      end
    else
      0
    end
  end

  defp maybe_reconcile_attempt(story_dir, story_id_fallback, attempt, reason)
       when is_integer(attempt) and attempt > 0 do
    dir = attempt_dir(story_dir, attempt)
    files = build_attempt_files(story_dir, dir)
    metadata = read_json_file(files.metadata)

    if orphaned_step_retry_attempt?(metadata) do
      timestamp = now_iso8601()

      reconciled =
        metadata
        |> Map.put("status", "failed")
        |> Map.put("ended_at", timestamp)
        |> Map.put("error", reason)

      story_id = Map.get(reconciled, "story_id") || story_id_fallback

      with :ok <- write_json(files.metadata, reconciled),
           :ok <-
             append_jsonl(files.attempts_index, %{
               "event" => "attempt_finished",
               "story_id" => story_id,
               "attempt" => attempt,
               "runner_attempt" => Map.get(reconciled, "runner_attempt"),
               "timestamp" => timestamp,
               "status" => "failed",
               "error" => reason,
               "retry_mode" => Map.get(reconciled, "retry_mode", "full_rerun"),
               "retry_provenance" => Map.get(reconciled, "retry_provenance", %{})
             }) do
        1
      else
        {:error, write_reason} ->
          Logger.warning(
            "failed to reconcile orphaned step retry attempt=#{attempt} story=#{story_id}: #{inspect(write_reason)}"
          )

          0
      end
    else
      0
    end
  end

  defp orphaned_step_retry_attempt?(metadata) when is_map(metadata) do
    status =
      metadata
      |> Map.get("status")
      |> optional_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    retry_step = metadata |> Map.get("retry_step") |> optional_string()
    ended_at = metadata |> Map.get("ended_at") |> optional_string()

    status == "running" and is_binary(retry_step) and is_nil(ended_at)
  end

  defp orphaned_step_retry_attempt?(_metadata), do: false

  defp story_dir(project_root, story_id) do
    Path.join([project_root | @base_log_dir] ++ [sanitize_story_id(story_id)])
  end

  defp attempt_dir(story_dir, attempt) do
    Path.join(
      story_dir,
      "attempt-#{attempt |> Integer.to_string() |> String.pad_leading(4, "0")}"
    )
  end

  defp build_attempt_files(story_dir, attempt_dir) do
    steps_dir = Path.join(attempt_dir, @steps_dir_name)

    %{
      attempts_index: Path.join(story_dir, "attempts.jsonl"),
      metadata: Path.join(attempt_dir, "metadata.json"),
      events: Path.join(attempt_dir, "events.jsonl"),
      run: Path.join(attempt_dir, "run.log"),
      worker: Path.join(attempt_dir, "worker.log"),
      reviewer: Path.join(attempt_dir, "reviewer.log"),
      tester: Path.join(attempt_dir, "tester.log"),
      checks: Path.join(attempt_dir, "checks.log"),
      runtime: Path.join(attempt_dir, "runtime.log"),
      agent: Path.join(attempt_dir, "agent.log"),
      agent_stdout: Path.join(attempt_dir, "agent_stdout.log"),
      reviewer_stdout: Path.join(attempt_dir, "reviewer_stdout.log"),
      tester_stdout: Path.join(attempt_dir, "tester_stdout.log"),
      review_json: Path.join(attempt_dir, "review.json"),
      review_cycles_dir: Path.join(attempt_dir, "review_cycles"),
      testing_json: Path.join(attempt_dir, "testing.json"),
      testing_cycles_dir: Path.join(attempt_dir, "testing_cycles"),
      testing_report: Path.join(attempt_dir, "testing_report.json"),
      testing_artifacts_dir: Path.join(attempt_dir, "testing_artifacts"),
      steps_dir: steps_dir,
      step_events: Path.join(steps_dir, @step_events_path)
    }
  end

  defp ensure_append_files(files) do
    base_files = [
      files.attempts_index,
      files.events,
      files.run,
      files.worker,
      files.reviewer,
      files.tester,
      files.checks,
      files.runtime,
      files.agent,
      files.agent_stdout,
      files.reviewer_stdout,
      files.tester_stdout
    ]

    with :ok <- ensure_steps_root(files) do
      base_files
      |> Enum.reduce_while(:ok, fn path, _acc ->
        case File.write(path, "", [:append]) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp ensure_steps_root(files) do
    steps_dir = Map.get(files, :steps_dir)
    step_events = Map.get(files, :step_events)

    with true <- is_binary(steps_dir) or {:error, :invalid_steps_dir},
         :ok <- File.mkdir_p(steps_dir),
         true <- is_binary(step_events) or {:error, :invalid_step_events_path},
         :ok <- File.write(step_events, "", [:append]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_step_log_paths}
      error -> {:error, error}
    end
  end

  defp append_step_event(context, event, _human_line, category)
       when is_map(context) and is_map(event) do
    with {:ok, bucket} <- step_event_bucket(event),
         {:ok, seq} <- step_event_sequence(context, bucket, event),
         {:ok, paths} <- ensure_step_paths(context, bucket, seq),
         step_category <- step_log_category(bucket, category),
         step_human_line <- format_human_line(event, step_category),
         enriched <-
           Map.put(event, "step_log", %{"bucket" => Atom.to_string(bucket), "seq" => seq}),
         :ok <- append_jsonl(paths.event_path, enriched),
         :ok <- append_text(paths.human_path, step_human_line),
         :ok <-
           append_jsonl(context.files.step_events, %{
             "timestamp" => Map.get(event, "timestamp") || now_iso8601(),
             "type" => Map.get(event, "type"),
             "bucket" => Atom.to_string(bucket),
             "seq" => seq,
             "event" => event,
             "event_path" => paths.event_path,
             "human_path" => paths.human_path
           }) do
      :ok
    else
      :ignore ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_step_event(_context, _event, _human_line, _category), do: :ok

  defp step_log_category(:agent, _category), do: :agent
  defp step_log_category(_bucket, category), do: category

  defp step_event_bucket(event) when is_map(event) do
    type = Map.get(event, "type")

    bucket =
      Enum.find_value(@step_event_buckets, fn {bucket, types} ->
        if type in types, do: bucket, else: nil
      end)

    case bucket do
      nil -> :ignore
      value -> {:ok, value}
    end
  end

  defp step_event_bucket(_event), do: :ignore

  defp step_event_sequence(context, :agent, event) do
    turn = positive_integer(Map.get(event, "turn"), nil)

    if is_integer(turn) and turn > 0,
      do: {:ok, turn},
      else: sequence_for_non_start_event(context, :agent, event)
  end

  defp step_event_sequence(context, :checks, event) do
    cycle = positive_integer(Map.get(event, "cycle"), nil)

    if is_integer(cycle) and cycle > 0,
      do: {:ok, cycle},
      else: sequence_for_non_start_event(context, :checks, event)
  end

  defp step_event_sequence(context, :review, event) do
    cycle = positive_integer(Map.get(event, "cycle"), nil)

    if is_integer(cycle) and cycle > 0,
      do: {:ok, cycle},
      else: sequence_for_non_start_event(context, :review, event)
  end

  defp step_event_sequence(context, :testing, event) do
    cycle = positive_integer(Map.get(event, "cycle"), nil)

    if is_integer(cycle) and cycle > 0,
      do: {:ok, cycle},
      else: sequence_for_non_start_event(context, :testing, event)
  end

  defp step_event_sequence(context, bucket, event),
    do: sequence_for_non_start_event(context, bucket, event)

  defp sequence_for_non_start_event(context, bucket, event) do
    if step_start_event?(bucket, event) do
      next_step_sequence(context, bucket)
    else
      current_or_next_step_sequence(context, bucket)
    end
  end

  defp step_start_event?(bucket, event) when is_atom(bucket) and is_map(event) do
    type = Map.get(event, "type")
    MapSet.member?(Map.get(@step_start_events, bucket, MapSet.new()), type)
  end

  defp step_start_event?(_bucket, _event), do: false

  defp current_or_next_step_sequence(context, bucket) do
    case last_step_sequence(context, bucket) do
      {:ok, seq} when is_integer(seq) and seq > 0 -> {:ok, seq}
      _other -> next_step_sequence(context, bucket)
    end
  end

  defp last_step_sequence(context, bucket) do
    pattern =
      context
      |> step_event_file(bucket, nil)
      |> case do
        value when is_binary(value) -> Regex.escape(value)
        _other -> nil
      end

    if is_binary(pattern) and File.exists?(context.files.step_events) do
      seq =
        context.files.step_events
        |> File.stream!([], :line)
        |> Enum.reduce(0, fn line, acc ->
          case Jason.decode(String.trim(line)) do
            {:ok, payload} when is_map(payload) ->
              payload_path = Map.get(payload, "event_path")
              payload_seq = positive_integer(Map.get(payload, "seq"), 0)

              if is_binary(payload_path) and Regex.match?(~r/^#{pattern}$/, payload_path) do
                max(acc, payload_seq)
              else
                acc
              end

            _other ->
              acc
          end
        end)

      {:ok, seq}
    else
      {:ok, 0}
    end
  rescue
    _ -> {:ok, 0}
  end

  defp next_step_sequence(context, bucket) do
    case last_step_sequence(context, bucket) do
      {:ok, seq} when is_integer(seq) -> {:ok, seq + 1}
      _other -> {:ok, 1}
    end
  end

  defp ensure_step_paths(context, bucket, seq)
       when is_map(context) and is_atom(bucket) and is_integer(seq) and seq > 0 do
    step_dir = step_directory(context, bucket, seq)
    event_path = step_event_file(context, bucket, seq)
    human_path = step_human_file(context, bucket, seq)

    with true <- is_binary(step_dir) or {:error, :invalid_step_dir},
         true <- is_binary(event_path) or {:error, :invalid_step_event_path},
         true <- is_binary(human_path) or {:error, :invalid_step_human_path},
         :ok <- File.mkdir_p(step_dir),
         :ok <- File.write(event_path, "", [:append]),
         :ok <- File.write(human_path, "", [:append]) do
      {:ok, %{event_path: event_path, human_path: human_path}}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_step_log_paths}
      error -> {:error, error}
    end
  end

  defp ensure_step_paths(_context, _bucket, _seq), do: {:error, :invalid_step_selector}

  defp step_directory(context, bucket, seq) do
    steps_dir = get_in(context, [:files, :steps_dir])

    if is_binary(steps_dir) and is_atom(bucket) and is_integer(seq) and seq > 0 do
      Path.join(
        steps_dir,
        "#{Atom.to_string(bucket)}-#{String.pad_leading(Integer.to_string(seq), 4, "0")}"
      )
    else
      nil
    end
  end

  defp step_event_file(context, bucket, seq) when is_integer(seq) and seq > 0 do
    case step_directory(context, bucket, seq) do
      nil -> nil
      dir -> Path.join(dir, "events.jsonl")
    end
  end

  defp step_event_file(context, bucket, nil) do
    steps_dir = get_in(context, [:files, :steps_dir])

    if is_binary(steps_dir) and is_atom(bucket) do
      Path.join(steps_dir, "#{Atom.to_string(bucket)}-*")
    else
      nil
    end
  end

  defp step_human_file(context, bucket, seq) do
    case step_directory(context, bucket, seq) do
      nil -> nil
      dir -> Path.join(dir, "step.log")
    end
  end

  defp next_attempt_number(story_dir) do
    case File.ls(story_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&parse_attempt_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> 0 end)
        |> Kernel.+(1)

      {:error, :enoent} ->
        1

      {:error, _reason} ->
        1
    end
  end

  defp parse_attempt_entry("attempt-" <> rest) do
    case Integer.parse(rest) do
      {attempt, ""} when attempt > 0 -> attempt
      _other -> nil
    end
  end

  defp parse_attempt_entry(_entry), do: nil

  defp initial_metadata(
         story_id,
         issue_id,
         identifier,
         attempt,
         runner_attempt,
         project_root,
         attempt_dir,
         files,
         retry_mode,
         retry_provenance,
         metadata_overrides
       ) do
    extra_metadata =
      metadata_overrides
      |> stringify_map()
      |> Map.drop([
        "story_id",
        "issue_id",
        "identifier",
        "attempt",
        "runner_attempt",
        "status",
        "started_at",
        "ended_at",
        "project_root",
        "attempt_dir",
        "files",
        "retry_mode",
        "retry_provenance"
      ])

    %{
      "story_id" => story_id,
      "issue_id" => optional_string(issue_id),
      "identifier" => optional_string(identifier),
      "attempt" => attempt,
      "runner_attempt" => runner_attempt,
      "retry_mode" => normalize_retry_mode(retry_mode),
      "retry_provenance" => normalize_retry_provenance(retry_provenance),
      "status" => "running",
      "run_state" => RunState.to_storage_map(RunState.from_status(:running)),
      "started_at" => now_iso8601(),
      "ended_at" => nil,
      "project_root" => project_root,
      "attempt_dir" => attempt_dir,
      "files" => %{
        "run" => files.run,
        "worker" => files.worker,
        "reviewer" => files.reviewer,
        "tester" => files.tester,
        "checks" => files.checks,
        "runtime" => files.runtime,
        "events" => files.events,
        "agent" => files.agent,
        "agent_stdout" => files.agent_stdout,
        "reviewer_stdout" => files.reviewer_stdout,
        "tester_stdout" => files.tester_stdout,
        "review_json" => files.review_json,
        "review_cycles_dir" => files.review_cycles_dir,
        "testing_json" => files.testing_json,
        "testing_cycles_dir" => files.testing_cycles_dir,
        "testing_report" => files.testing_report,
        "testing_artifacts_dir" => files.testing_artifacts_dir,
        "steps_dir" => files.steps_dir,
        "step_events" => files.step_events
      }
    }
    |> Map.merge(extra_metadata)
  end

  defp testing_report_metadata(files) when is_map(files) do
    report =
      files
      |> testing_report_file_path()
      |> read_json_file()

    if map_size(report) > 0 do
      %{
        "testing_report" => report,
        "testing_artifacts" => Map.get(report, "artifacts", [])
      }
    else
      %{}
    end
  end

  defp testing_report_metadata(_files), do: %{}

  defp testing_report_file_path(files) when is_map(files) do
    explicit = Map.get(files, :testing_report) || Map.get(files, "testing_report")

    cond do
      is_binary(explicit) and File.exists?(explicit) ->
        explicit

      true ->
        fallback = Map.get(files, :testing_json) || Map.get(files, "testing_json")
        if is_binary(fallback) and File.exists?(fallback), do: fallback, else: nil
    end
  end

  defp testing_report_file_path(_files), do: nil

  defp parse_prepare_attempt_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      retry_mode = normalize_retry_mode(Keyword.get(opts, :retry_mode, :full_rerun))
      retry_provenance = normalize_retry_provenance(Keyword.get(opts, :retry_provenance, %{}))

      metadata_overrides =
        normalize_metadata_overrides(Keyword.get(opts, :metadata_overrides, %{}))

      {retry_mode, retry_provenance, metadata_overrides}
    else
      {"full_rerun", %{}, %{}}
    end
  end

  defp parse_prepare_attempt_opts(opts) when is_map(opts) do
    retry_mode =
      opts
      |> field(:retry_mode)
      |> normalize_retry_mode()

    retry_provenance =
      opts
      |> field(:retry_provenance)
      |> normalize_retry_provenance()

    metadata_overrides = normalize_metadata_overrides(opts)

    {retry_mode, retry_provenance, metadata_overrides}
  end

  defp parse_prepare_attempt_opts(_opts), do: {"full_rerun", %{}, %{}}

  defp normalize_metadata_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_metadata_overrides(_overrides), do: %{}

  defp normalize_event(event, context) do
    normalized = stringify_map(event)

    type =
      normalized
      |> Map.get("type")
      |> to_string()

    timestamp =
      normalized
      |> Map.get("timestamp")
      |> normalize_timestamp()

    recovery_guidance =
      normalized
      |> Map.get("recovery_guidance")
      |> RecoveryGuidance.normalize()

    recovery_guidance =
      recovery_guidance ||
        normalized
        |> Map.get("reason")
        |> optional_string()
        |> RecoveryGuidance.parse()

    recovery_guidance =
      recovery_guidance ||
        normalized
        |> Map.get("error")
        |> optional_string()
        |> RecoveryGuidance.parse()

    normalized
    |> Map.put("type", type)
    |> Map.put("timestamp", timestamp)
    |> Map.put("run_state", RunState.to_storage_map(RunState.from_event(normalized, nil)))
    |> Map.put_new("issue_id", context.issue_id)
    |> Map.put_new("identifier", context.identifier)
    |> Map.put_new("story_id", context.story_id)
    |> Map.put_new("attempt", context.attempt)
    |> maybe_put_recovery_guidance(recovery_guidance)
  end

  defp maybe_put_recovery_guidance(event, %{summary: _summary, commands: _commands} = guidance) do
    Map.put(event, "recovery_guidance", %{
      "summary" => guidance.summary,
      "commands" => guidance.commands
    })
  end

  defp maybe_put_recovery_guidance(event, _guidance), do: event

  defp normalize_timestamp(nil), do: now_iso8601()

  defp normalize_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_iso8601(datetime)
      _other -> value
    end
  end

  defp normalize_timestamp(value), do: to_string(value)

  defp category_for_event(type) do
    cond do
      type in @review_events -> :reviewer
      type in @testing_events -> :tester
      type in @checks_events -> :checks
      type in @runtime_events -> :runtime
      type in @worker_events -> :worker
      true -> :worker
    end
  end

  defp category_path(files, :worker), do: files.worker
  defp category_path(files, :reviewer), do: files.reviewer
  defp category_path(files, :tester), do: files.tester
  defp category_path(files, :checks), do: files.checks
  defp category_path(files, :runtime), do: files.runtime

  defp maybe_append_agent_log(files, event) do
    if Map.get(event, "type") in @agent_log_events do
      output = optional_string(Map.get(event, "output"))

      if output do
        turn = Map.get(event, "turn") || Map.get(event, "cycle") || "?"
        separator = "\n--- Turn #{turn} ---\n"
        append_text(files.agent, separator <> output <> "\n")
      else
        :ok
      end
    else
      :ok
    end
  end

  defp format_human_line(event, category) do
    timestamp = Map.get(event, "timestamp", now_iso8601())
    type = Map.get(event, "type", "unknown")

    detail_fields =
      event
      |> Map.drop([
        "type",
        "timestamp",
        "issue_id",
        "identifier",
        "story_id",
        "attempt",
        "args",
        "output",
        "raw_output",
        "output_preview",
        "prompt"
      ])
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{format_detail_value(value)}" end)

    header =
      "[#{timestamp}] [#{category}] #{type}" <>
        if(detail_fields == "", do: "", else: " #{detail_fields}")

    output_block = output_block(event, category)

    if output_block == "" do
      header <> "\n"
    else
      header <> "\n" <> output_block <> "\n"
    end
  end

  # Keep worker logs focused on orchestrator lifecycle signals. Agent transcript
  # output belongs in agent-specific logs, not worker.log / run.log worker entries.
  defp output_block(_event, :worker), do: ""

  defp output_block(event, _category) do
    output = optional_string(Map.get(event, "output"))
    raw_output = optional_string(Map.get(event, "raw_output"))
    output_preview = optional_string(Map.get(event, "output_preview"))

    [
      format_output_section("output", output),
      format_output_section("raw_output", raw_output),
      format_output_section("output_preview", output_preview)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_output_section(_label, nil), do: ""

  defp format_output_section(label, value) do
    "#{label}:\n#{value}"
  end

  defp format_detail_value(value) when is_binary(value) do
    if String.contains?(value, [" ", "\n", "\t"]) do
      inspect(value)
    else
      value
    end
  end

  defp format_detail_value(value) when is_map(value) or is_list(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> encoded
      _other -> inspect(value)
    end
  end

  defp format_detail_value(value), do: to_string(value)

  defp append_jsonl(path, map) do
    line = Jason.encode_to_iodata!(map)
    File.write(path, [line, "\n"], [:append])
  end

  defp append_text(path, text) do
    File.write(path, text, [:append])
  end

  defp write_json(path, map) do
    payload = Jason.encode_to_iodata!(map, pretty: true)
    File.write(path, [payload, "\n"])
  end

  defp read_json_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      decoded
    else
      _other -> %{}
    end
  end

  defp read_json_file(_path), do: %{}

  defp normalize_status_value(value) when is_binary(value), do: value
  defp normalize_status_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_status_value(value), do: to_string(value)

  defp completion_run_state(update, files) when is_map(update) and is_map(files) do
    status = Map.get(update, "status")

    prior_state =
      files.metadata
      |> read_json_file()
      |> Map.get("run_state")

    status
    |> RunState.from_status(prior_state)
    |> RunState.to_storage_map()
  end

  defp completion_run_state(_update, _files), do: RunState.to_storage_map(RunState.unknown())

  defp derive_last_successful_turn(events) when is_list(events) do
    events
    |> Enum.filter(fn event -> run_event_type(event) == "turn_succeeded" end)
    |> Enum.map(fn event -> positive_integer(field(event, :turn), nil) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp derive_last_successful_turn(_events), do: nil

  defp maybe_put_last_successful_turn(update, events) when is_map(update) do
    case derive_last_successful_turn(events) do
      turn when is_integer(turn) and turn > 0 ->
        Map.put(update, :last_successful_turn, turn)

      _other ->
        update
    end
  end

  defp maybe_put_last_successful_turn(update, _events), do: update

  defp maybe_put_recovery_guidance(update, events, fallback_error) when is_map(update) do
    guidance =
      recovery_guidance_from_events(events) ||
        fallback_error
        |> optional_string()
        |> RecoveryGuidance.parse()

    case guidance do
      %{summary: _summary, commands: _commands} -> Map.put(update, :recovery_guidance, guidance)
      _other -> update
    end
  end

  defp maybe_put_recovery_guidance(update, _events, _fallback_error), do: update

  defp recovery_guidance_from_events(events) when is_list(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      RecoveryGuidance.normalize(field(event, :recovery_guidance)) ||
        event
        |> field(:reason)
        |> optional_string()
        |> RecoveryGuidance.parse() ||
        event
        |> field(:error)
        |> optional_string()
        |> RecoveryGuidance.parse()
    end)
  end

  defp recovery_guidance_from_events(_events), do: nil

  defp run_event_type(event) when is_map(event) do
    case field(event, :type) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> nil
    end
  end

  defp run_event_type(_event), do: nil

  @default_event_slice_limit 2_000
  @max_event_slice_limit 2_000

  defp read_events_slice(path, opts) when is_binary(path) and is_list(opts) do
    since = non_negative_integer(Keyword.get(opts, :since), 0)

    limit =
      Keyword.get(opts, :limit)
      |> positive_integer(@default_event_slice_limit)
      |> min(@max_event_slice_limit)

    if File.exists?(path) and File.regular?(path) do
      path
      |> File.stream!([], :line)
      |> Stream.with_index(1)
      |> Stream.drop_while(fn {_line, idx} -> idx <= since end)
      |> Enum.reduce_while({[], 0, since}, fn {line, idx}, {events_rev, count, _last_idx} ->
        next_events_rev =
          case Jason.decode(String.trim(line)) do
            {:ok, event} when is_map(event) -> [event | events_rev]
            _other -> events_rev
          end

        next_count = count + 1

        if next_count >= limit do
          {:halt, {next_events_rev, next_count, idx}}
        else
          {:cont, {next_events_rev, next_count, idx}}
        end
      end)
      |> then(fn {events_rev, _count, last_idx} ->
        {:ok, Enum.reverse(events_rev), last_idx}
      end)
    else
      {:ok, [], since}
    end
  rescue
    error -> {:error, "failed to read events: #{Exception.message(error)}"}
  end

  defp read_events_slice(_path, _opts), do: {:error, "invalid events path"}

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _other -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp non_negative_integer(value, _fallback) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> int
      _other -> fallback
    end
  end

  defp non_negative_integer(_value, fallback), do: fallback

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_map(_value), do: %{}

  defp normalize_retry_mode(mode) when mode in [:full_rerun, :agent_continuation] do
    Atom.to_string(mode)
  end

  defp normalize_retry_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      "agent_continuation" -> "agent_continuation"
      "agent-continuation" -> "agent_continuation"
      _other -> "full_rerun"
    end
  end

  defp normalize_retry_mode(_mode), do: "full_rerun"

  defp normalize_retry_provenance(value) when is_map(value), do: stringify_map(value)
  defp normalize_retry_provenance(_value), do: %{}

  defp stringify_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp stringify_value(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify_value(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify_value(nil), do: nil
  defp stringify_value(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp sanitize_story_id(story_id) do
    story_id
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp expand_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> case do
      "~" -> System.user_home!()
      <<"~/", rest::binary>> -> Path.join(System.user_home!(), rest)
      other -> Path.expand(other)
    end
  end

  defp expand_path(_path), do: File.cwd!()

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_map, _key), do: nil

  defp optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp optional_string(_value), do: nil

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end
end
