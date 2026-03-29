defmodule Kollywood.StepRetry do
  @moduledoc """
  Operator-triggered retries for failed terminal steps.

  Step retries run from a failed phase forward (`checks`, `review`, or `publish`)
  while reusing the existing workspace and preserving prior attempts in run logs.
  """

  require Logger

  alias Kollywood.AgentRunner
  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Orchestrator.RunSettingsSnapshot
  alias Kollywood.Projects
  alias Kollywood.ServiceConfig
  alias Kollywood.StoryExecutionOverrides
  alias Kollywood.Tracker
  alias Kollywood.Tracker.PrdJson
  alias Kollywood.Workspace

  @type step :: :checks | :review | :publish

  @step_labels %{
    checks: "Retry checks",
    review: "Retry review",
    publish: "Retry publish"
  }

  @doc """
  Returns retry action metadata for a failed attempt.

  Returns `nil` when the source attempt did not fail in a retryable terminal step.
  """
  @spec retry_action(map(), String.t(), String.t() | integer() | nil) :: map() | nil
  def retry_action(project, story_id, source_attempt) do
    with {:ok, parsed_attempt} <- parse_attempt(source_attempt),
         {:ok, source} <- load_source_attempt(project, story_id, parsed_attempt),
         {:ok, retry_step} <- failed_step(source.events) do
      reason =
        with {:ok, config, _prompt_template, _workflow_identity} <- load_workflow(project),
             :ok <- ensure_common_preconditions(config, source.metadata),
             :ok <- ensure_prior_phase_outputs(retry_step, config, source.events),
             {:ok, issue} <- load_issue(project, story_id),
             {:ok, _workspace} <- build_workspace(config, issue.identifier, source.metadata) do
          nil
        else
          {:error, precondition_reason} -> precondition_reason
        end

      %{
        "step" => Atom.to_string(retry_step),
        "label" => Map.fetch!(@step_labels, retry_step),
        "attempt" => source.attempt,
        "enabled" => is_nil(reason),
        "reason" => reason
      }
    else
      _ -> nil
    end
  end

  @doc """
  Executes a step retry for an existing failed attempt.

  Returns the newly-created attempt metadata on success.
  """
  @spec retry(map(), String.t(), String.t() | integer(), step() | String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def retry(project, story_id, source_attempt, step) do
    with {:ok, retry_step} <- parse_step(step),
         {:ok, parsed_attempt} <- parse_attempt(source_attempt),
         {:ok, source} <- load_source_attempt(project, story_id, parsed_attempt),
         {:ok, config, prompt_template, workflow_identity} <- load_workflow(project),
         :ok <- ensure_retry_step_failed(source.events, retry_step),
         :ok <- ensure_common_preconditions(config, source.metadata),
         :ok <- ensure_prior_phase_outputs(retry_step, config, source.events),
         {:ok, issue} <- load_issue(project, story_id),
         {:ok, resolved_story_execution} <- StoryExecutionOverrides.resolve(config, issue),
         {:ok, workspace} <- build_workspace(config, issue.identifier, source.metadata),
         {:ok, run_log_context} <-
           prepare_retry_logs(
             config,
             project,
             issue,
             source,
             retry_step,
             workflow_identity,
             resolved_story_execution.settings_snapshot
           ) do
      on_event = fn event ->
        case RunLogs.append_event(run_log_context, event) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to append step retry event: #{reason}")
            :ok
        end
      end

      run_opts = [
        config: resolved_story_execution.config,
        story_overrides_resolved: true,
        run_settings_snapshot: resolved_story_execution.settings_snapshot,
        prompt_template: prompt_template,
        attempt: run_log_context.attempt,
        workspace: workspace,
        log_files: run_log_context.files,
        on_event: on_event
      ]

      run_result = AgentRunner.retry_step(issue, retry_step, run_opts)

      finalize_retry_result(
        config,
        issue,
        source,
        retry_step,
        run_log_context,
        run_result
      )
    end
  end

  defp finalize_retry_result(
         config,
         issue,
         source,
         retry_step,
         run_log_context,
         {:ok, %Result{} = result}
       ) do
    with :ok <- complete_run_logs(run_log_context, result),
         :ok <- tracker_mark_success(config, issue, run_log_context, result) do
      {:ok,
       %{
         story_id: issue.identifier,
         attempt: run_log_context.attempt,
         parent_attempt: source.attempt,
         retry_step: Atom.to_string(retry_step),
         status: "ok"
       }}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_retry_result(
         config,
         issue,
         source,
         retry_step,
         run_log_context,
         {:error, %Result{} = result}
       ) do
    _ = complete_run_logs(run_log_context, result)

    reason = optional_string(result.error) || "step retry failed"
    failure_attempt = run_log_context.attempt

    reason =
      case tracker_mark_failed(config, issue.id, reason, failure_attempt) do
        :ok ->
          reason

        {:error, tracker_reason} ->
          "#{reason}; failed to update tracker: #{tracker_reason}"
      end

    {:error,
     "#{reason} (step=#{Atom.to_string(retry_step)}, source_attempt=#{source.attempt}, parent_attempt=#{source.attempt})"}
  end

  defp complete_run_logs(run_log_context, result) do
    case RunLogs.complete_attempt(run_log_context, result) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tracker_mark_success(config, issue, run_log_context, %Result{} = result) do
    issue_id = issue.id
    done_metadata = tracker_done_metadata(result, run_log_context)

    cond do
      publish_pending_merge?(result.events) ->
        tracker_call(config, :mark_pending_merge, [
          issue_id,
          pending_merge_metadata(result, done_metadata)
        ])

      true ->
        with :ok <- tracker_call(config, :mark_done, [issue_id, done_metadata]),
             :ok <- maybe_tracker_mark_merged(config, issue_id, done_metadata, result.events) do
          :ok
        end
    end
  end

  defp tracker_done_metadata(%Result{} = result, run_log_context) do
    base = %{
      status: result.status,
      turn_count: result.turn_count,
      ended_at: result.ended_at,
      workspace_path: result.workspace_path
    }

    Map.merge(base, RunLogs.tracker_metadata(run_log_context))
  end

  defp pending_merge_metadata(events_result, done_metadata) when is_map(done_metadata) do
    done_metadata
    |> maybe_put(:pr_url, event_field(events_result.events, "publish_pr_created", :pr_url))
    |> maybe_put(
      :merge_failed_reason,
      event_field(events_result.events, "publish_merge_failed", :reason)
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_tracker_mark_merged(config, issue_id, done_metadata, events) when is_list(events) do
    if publish_merged?(events) do
      tracker_call(config, :mark_merged, [issue_id, done_metadata])
    else
      :ok
    end
  end

  defp tracker_mark_failed(config, issue_id, reason, attempt) do
    tracker_call(config, :mark_failed, [issue_id, reason, attempt])
  end

  defp tracker_call(%Config{} = config, function_name, args) when is_atom(function_name) do
    tracker = tracker_module(config)
    full_args = [config | args]
    arity = length(full_args)

    try do
      if function_exported?(tracker, function_name, arity) do
        case apply(tracker, function_name, full_args) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, to_string(reason)}

          other ->
            {:error,
             "tracker #{inspect(tracker)} returned #{inspect(other)} for #{function_name}/#{arity}"}
        end
      else
        :ok
      end
    rescue
      error ->
        {:error,
         "tracker #{inspect(tracker_module(config))} failed in #{function_name}/#{arity}: #{Exception.message(error)}"}
    end
  end

  defp tracker_module(%Config{} = config) do
    kind = get_in(config, [Access.key(:tracker, %{}), Access.key(:kind)])
    Tracker.module_for_kind(kind)
  end

  defp prepare_retry_logs(
         config,
         project,
         issue,
         source,
         retry_step,
         workflow_identity,
         run_settings_snapshot
       ) do
    log_config = config_for_run_logs(config, project)

    metadata = %{
      "parent_attempt" => source.attempt,
      "retry_step" => Atom.to_string(retry_step),
      "settings_snapshot" =>
        RunSettingsSnapshot.build(log_config, workflow_identity: workflow_identity),
      "run_settings" => if(is_map(run_settings_snapshot), do: run_settings_snapshot, else: %{})
    }

    case RunLogs.prepare_attempt(log_config, issue, source.runner_attempt, metadata) do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_for_run_logs(%Config{} = config, project) do
    project_slug = field(project, :slug)
    tracker = Map.put(config.tracker || %{}, :project_slug, project_slug)
    %{config | tracker: tracker}
  end

  defp ensure_common_preconditions(config, metadata) do
    with :ok <- ensure_attempt_failed(metadata),
         {:ok, workspace_path} <- workspace_path_from_metadata(metadata),
         :ok <- ensure_workspace_exists(workspace_path),
         :ok <- ensure_branch_artifacts(config, workspace_path) do
      :ok
    end
  end

  defp ensure_attempt_failed(metadata) when is_map(metadata) do
    status =
      metadata
      |> Map.get("status")
      |> normalize_status()

    if status == "failed" do
      :ok
    else
      {:error, "step retry is only available for failed attempts"}
    end
  end

  defp ensure_attempt_failed(_metadata), do: {:error, "source attempt metadata is unavailable"}

  defp ensure_workspace_exists(workspace_path) when is_binary(workspace_path) do
    if File.dir?(workspace_path) do
      :ok
    else
      {:error, "workspace is missing: #{workspace_path}"}
    end
  end

  defp ensure_workspace_exists(_workspace_path),
    do: {:error, "workspace path is missing from source attempt metadata"}

  defp ensure_branch_artifacts(%Config{} = config, workspace_path) do
    if workspace_strategy(config) == :worktree do
      case current_branch(workspace_path) do
        {:ok, _branch} ->
          :ok

        {:error, reason} ->
          {:error, "workspace branch artifacts are unavailable: #{reason}"}
      end
    else
      :ok
    end
  end

  defp ensure_retry_step_failed(events, retry_step) do
    case last_failed_step(events) do
      ^retry_step ->
        :ok

      nil ->
        {:error, "source attempt did not fail in checks, review, or publish"}

      other ->
        {:error, "source attempt failed in #{Atom.to_string(other)}; retry that step instead"}
    end
  end

  defp ensure_prior_phase_outputs(:checks, _config, events) do
    if event_present?(events, "turn_succeeded") do
      :ok
    else
      {:error, "cannot retry checks: no completed agent turn output was recorded"}
    end
  end

  defp ensure_prior_phase_outputs(:review, config, events) do
    if checks_required?(config) and not event_present?(events, "checks_passed") do
      {:error, "cannot retry review: required check outputs are missing"}
    else
      :ok
    end
  end

  defp ensure_prior_phase_outputs(:publish, config, events) do
    with :ok <- ensure_checks_outputs_for_publish(config, events),
         :ok <- ensure_review_outputs_for_publish(config, events) do
      :ok
    end
  end

  defp ensure_checks_outputs_for_publish(config, events) do
    if checks_required?(config) and not event_present?(events, "checks_passed") do
      {:error, "cannot retry publish: checks did not pass in the source attempt"}
    else
      :ok
    end
  end

  defp ensure_review_outputs_for_publish(config, events) do
    if review_enabled?(config) and not event_present?(events, "review_passed") do
      {:error, "cannot retry publish: review did not pass in the source attempt"}
    else
      :ok
    end
  end

  defp load_source_attempt(project, story_id, source_attempt) do
    with {:ok, project_root} <- project_data_root(project),
         true <- non_empty_string?(story_id) or {:error, "story_id is required"},
         {:ok, resolved} <- RunLogs.resolve_attempt(project_root, story_id, source_attempt) do
      events = read_events_jsonl(resolved.files.events)

      {:ok,
       %{
         attempt: resolved.attempt,
         runner_attempt: normalize_runner_attempt(resolved.metadata["runner_attempt"]),
         metadata: resolved.metadata,
         files: resolved.files,
         events: events
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "story_id is required"}
    end
  end

  defp load_workflow(project) do
    path = Projects.workflow_path(project)

    cond do
      not non_empty_string?(path) ->
        {:error, "workflow file path is unavailable for this project"}

      not File.exists?(path) ->
        {:error, "workflow file does not exist: #{path}"}

      true ->
        with {:ok, content} <- File.read(path),
             {:ok, config, prompt_template} <- Config.parse(content) do
          workflow_identity = RunSettingsSnapshot.workflow_identity_from_file(path, content)
          config = inject_project_context(config, project)
          {:ok, config, prompt_template, workflow_identity}
        else
          {:error, reason} -> {:error, "failed to load workflow: #{reason}"}
        end
    end
  end

  defp inject_project_context(%Config{} = config, project) do
    tracker_path = Projects.tracker_path(project)
    workspace_root = ServiceConfig.project_workspace_root(field(project, :slug) || "default")
    workspace_source = Projects.local_path(project)

    tracker =
      config.tracker
      |> Map.put(:path, tracker_path)
      |> Map.put(:project_slug, nil)

    workspace =
      config.workspace
      |> Map.put_new(:root, workspace_root)
      |> maybe_put_if_present(:source, workspace_source)

    config
    |> Map.put(:project_provider, normalize_project_provider(field(project, :provider)))
    |> Map.put(:tracker, tracker)
    |> Map.put(:workspace, workspace)
  end

  defp normalize_project_provider(value) when value in [:github, :gitlab, :local], do: value
  defp normalize_project_provider("github"), do: :github
  defp normalize_project_provider("gitlab"), do: :gitlab
  defp normalize_project_provider("local"), do: :local
  defp normalize_project_provider(_value), do: nil

  defp maybe_put_if_present(map, _key, value) when not is_binary(value), do: map
  defp maybe_put_if_present(map, _key, value) when value == "", do: map
  defp maybe_put_if_present(map, key, value), do: Map.put_new(map, key, value)

  defp load_issue(project, story_id) do
    with tracker_path when is_binary(tracker_path) <- Projects.tracker_path(project),
         {:ok, stories} <- PrdJson.list_stories(tracker_path),
         story when is_map(story) <- Enum.find(stories, &(&1["id"] == story_id)) do
      {:ok, issue_from_story(story_id, story)}
    else
      nil ->
        {:error, "story not found: #{story_id}"}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, "tracker path is unavailable for this project"}
    end
  end

  defp issue_from_story(story_id, story) do
    %{
      id: story_id,
      identifier: story_id,
      title: optional_string(story["title"]) || story_id,
      description: optional_string(story["description"]) || ""
    }
  end

  defp build_workspace(config, identifier, metadata) do
    with {:ok, workspace_path} <- workspace_path_from_metadata(metadata),
         strategy <- workspace_strategy(config),
         {:ok, branch} <- workspace_branch(strategy, workspace_path) do
      key =
        identifier
        |> optional_string()
        |> Kernel.||(Path.basename(workspace_path))
        |> Workspace.sanitize_key()

      root =
        config
        |> get_in([Access.key(:workspace, %{}), Access.key(:root)])
        |> optional_string()
        |> Kernel.||(Path.dirname(workspace_path))

      {:ok,
       %Workspace{
         path: workspace_path,
         key: key,
         root: root,
         strategy: strategy,
         branch: branch
       }}
    end
  end

  defp workspace_path_from_metadata(metadata) when is_map(metadata) do
    case metadata |> Map.get("workspace_path") |> optional_string() do
      nil -> {:error, "workspace path is missing from source attempt metadata"}
      path -> {:ok, path}
    end
  end

  defp workspace_path_from_metadata(_metadata),
    do: {:error, "workspace path is missing from source attempt metadata"}

  defp workspace_strategy(%Config{} = config) do
    config
    |> get_in([Access.key(:workspace, %{}), Access.key(:strategy)])
    |> case do
      :worktree -> :worktree
      _other -> :clone
    end
  end

  defp workspace_branch(:worktree, workspace_path), do: current_branch(workspace_path)
  defp workspace_branch(_strategy, _workspace_path), do: {:ok, nil}

  defp current_branch(workspace_path) do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        case optional_string(branch) do
          nil -> {:error, "empty branch name"}
          trimmed -> {:ok, trimmed}
        end

      {output, code} ->
        {:error, "git rev-parse failed (exit #{code}): #{String.trim(output)}"}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  end

  defp project_data_root(project) do
    case field(project, :slug) do
      slug when is_binary(slug) and slug != "" ->
        {:ok, ServiceConfig.project_data_dir(slug)}

      _other ->
        {:error, "project slug is required for step retries"}
    end
  end

  defp parse_step(:checks), do: {:ok, :checks}
  defp parse_step(:review), do: {:ok, :review}
  defp parse_step(:publish), do: {:ok, :publish}
  defp parse_step("checks"), do: {:ok, :checks}
  defp parse_step("review"), do: {:ok, :review}
  defp parse_step("publish"), do: {:ok, :publish}

  defp parse_step(step) when is_binary(step) do
    step
    |> String.trim()
    |> String.downcase()
    |> parse_step()
  end

  defp parse_step(_step),
    do: {:error, "retry step must be one of: checks, review, publish"}

  defp parse_attempt(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_attempt(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {attempt, ""} when attempt > 0 -> {:ok, attempt}
      _other -> {:error, "attempt must be a positive integer"}
    end
  end

  defp parse_attempt(_value), do: {:error, "attempt must be a positive integer"}

  defp normalize_runner_attempt(value) when is_integer(value) and value >= 0, do: value

  defp normalize_runner_attempt(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> nil
    end
  end

  defp normalize_runner_attempt(_value), do: nil

  defp failed_step(events) when is_list(events) do
    case last_failed_step(events) do
      nil -> {:error, "source attempt did not fail in checks, review, or publish"}
      step -> {:ok, step}
    end
  end

  defp failed_step(_events),
    do: {:error, "source attempt did not fail in checks, review, or publish"}

  defp last_failed_step(events) when is_list(events) do
    Enum.reduce(events, nil, fn event, acc ->
      case event_type(event) do
        "checks_failed" -> :checks
        "review_failed" -> :review
        "review_error" -> :review
        "publish_failed" -> :publish
        _other -> acc
      end
    end)
  end

  defp last_failed_step(_events), do: nil

  defp event_present?(events, expected_type) when is_list(events) do
    Enum.any?(events, &(event_type(&1) == expected_type))
  end

  defp event_present?(_events, _expected_type), do: false

  defp event_type(event) when is_map(event) do
    case Map.get(event, :type) || Map.get(event, "type") do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp event_type(_event), do: ""

  defp event_field(events, expected_type, field_name)
       when is_list(events) and is_atom(field_name) do
    Enum.find_value(events, fn event ->
      if event_type(event) == expected_type do
        Map.get(event, field_name) || Map.get(event, Atom.to_string(field_name))
      else
        nil
      end
    end)
  end

  defp event_field(_events, _expected_type, _field_name), do: nil

  defp publish_pending_merge?(events) when is_list(events) do
    Enum.any?(events, &(event_type(&1) == "publish_pr_created"))
  end

  defp publish_pending_merge?(_events), do: false

  defp publish_merged?(events) when is_list(events) do
    Enum.any?(events, &(event_type(&1) == "publish_merged"))
  end

  defp publish_merged?(_events), do: false

  defp checks_required?(%Config{} = config) do
    config
    |> checks_config()
    |> Map.get(:required, [])
    |> Enum.any?(fn value -> is_binary(value) and String.trim(value) != "" end)
  end

  defp checks_config(%Config{} = config) do
    case Map.get(config, :checks) do
      checks when is_map(checks) ->
        checks

      _other ->
        case Map.get(config, :quality, %{}) |> Map.get(:checks) do
          checks when is_map(checks) -> checks
          _other -> %{}
        end
    end
  end

  defp review_enabled?(%Config{} = config) do
    review_config(config)
    |> Map.get(:enabled, false)
    |> truthy?()
  end

  defp review_config(%Config{} = config) do
    case Map.get(config, :review) do
      review when is_map(review) ->
        review

      _other ->
        case Map.get(config, :quality, %{}) |> Map.get(:review) do
          review when is_map(review) -> review
          _other -> %{}
        end
    end
  end

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "true" -> true
      "1" -> true
      "yes" -> true
      "on" -> true
      _other -> false
    end
  end

  defp truthy?(_value), do: false

  defp read_events_jsonl(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, event} when is_map(event) -> [event | acc]
          _other -> acc
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_events_jsonl(_path), do: []

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

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_status(value) when is_binary(value), do: String.trim(value) |> String.downcase()

  defp normalize_status(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_status()

  defp normalize_status(_value), do: ""
end
