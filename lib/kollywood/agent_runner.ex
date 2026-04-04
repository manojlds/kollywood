defmodule Kollywood.AgentRunner do
  @moduledoc """
  Runs one issue through the Stage 4 agent turn loop.

  The runner is intentionally orchestration-agnostic so it can be called by a
  future scheduler/orchestrator process.
  """

  require Logger

  alias Kollywood.Agent
  alias Kollywood.AgentRunner.ContinuationPrompt
  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.PromptBuilder
  alias Kollywood.Publisher
  alias Kollywood.Runtime
  alias Kollywood.StoryExecutionOverrides
  alias Kollywood.Tracker
  alias Kollywood.WorkflowStore
  alias Kollywood.Workspace

  @type mode :: :single_turn | :max_turns

  @type run_opt ::
          {:workflow_store, GenServer.server()}
          | {:config, Config.t()}
          | {:prompt_template, String.t()}
          | {:story_overrides_resolved, boolean()}
          | {:run_settings_snapshot, map()}
          | {:attempt, non_neg_integer() | nil}
          | {:workspace, Workspace.t()}
          | {:mode, mode()}
          | {:turn_limit, pos_integer()}
          | {:session_opts, map() | keyword()}
          | {:continuation, map() | keyword() | nil}
          | {:turn_opts, map() | keyword()}
          | {:on_event, (map() -> any())}

  @type run_opts :: [run_opt()]

  @doc """
  Executes an issue run using the configured adapter and workspace lifecycle.

  Returns `{:ok, %Result{}}` for successful runs and `{:error, %Result{}}` for
  failed runs.
  """
  def run_issue(issue, opts \\ [])

  @spec run_issue(map(), run_opts()) :: {:ok, Result.t()} | {:error, Result.t()}
  def run_issue(issue, opts) when is_map(issue) and is_list(opts) do
    started_at = DateTime.utc_now()

    with {:ok, on_event} <- parse_on_event(Keyword.get(opts, :on_event, &default_on_event/1)),
         {:ok, attempt} <- parse_attempt(Keyword.get(opts, :attempt)),
         {:ok, issue_meta} <- issue_meta(issue),
         {:ok, config, prompt_template, run_settings_snapshot} <- resolve_workflow(issue, opts),
         {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, :single_turn)),
         {:ok, turn_limit} <- parse_turn_limit(config, Keyword.get(opts, :turn_limit)),
         {:ok, session_opts} <-
           normalize_opts(Keyword.get(opts, :session_opts, %{}), "session_opts"),
         {:ok, continuation} <- parse_continuation_opts(Keyword.get(opts, :continuation)),
         {:ok, turn_opts} <- normalize_opts(Keyword.get(opts, :turn_opts, %{}), "turn_opts") do
      log_files = Keyword.get(opts, :log_files)

      state = %{
        issue: issue,
        issue_id: issue_meta.id,
        identifier: issue_meta.identifier,
        started_at: started_at,
        workspace: nil,
        runtime: Runtime.default_state(runtime_kind(config), config),
        session: nil,
        turn_count: 0,
        last_output: nil,
        events_rev: [],
        on_event: on_event,
        attempt: attempt,
        log_files: log_files,
        continuation: continuation
      }

      state =
        state
        |> emit(:run_started, %{
          attempt: attempt,
          mode: mode,
          turn_limit: turn_limit,
          retry_mode: continuation_retry_mode(continuation),
          run_settings: run_settings_snapshot
        })
        |> maybe_emit_continuation_context()

      case Workspace.create_for_issue(issue_meta.identifier, config) do
        {:ok, workspace} ->
          config = with_agent_browser_defaults(config, workspace)
          runtime = Runtime.init(runtime_kind(config), config, workspace)

          state =
            state
            |> Map.put(:workspace, workspace)
            |> Map.put(:runtime, runtime)
            |> emit(:workspace_ready, %{
              workspace_path: workspace.path,
              runtime_profile: runtime.profile
            })

          run_with_session(
            state,
            config,
            prompt_template,
            mode,
            turn_limit,
            session_opts,
            turn_opts
          )

        {:error, reason} ->
          fail(state, "Failed to prepare workspace: #{reason}")
      end
    else
      {:error, reason} ->
        result = %Result{
          status: :failed,
          started_at: started_at,
          ended_at: DateTime.utc_now(),
          error: reason
        }

        {:error, result}
    end
  end

  def run_issue(_issue, _opts) do
    started_at = DateTime.utc_now()

    result = %Result{
      status: :failed,
      started_at: started_at,
      ended_at: DateTime.utc_now(),
      error: "Issue must be a map and options must be a keyword list"
    }

    {:error, result}
  end

  @doc """
  Retries a failed terminal step (`checks`, `review`, `testing`, or `publish`) using an
  existing workspace and skipping agent turns.
  """
  @spec retry_step(map(), :checks | :review | :testing | :publish, run_opts()) ::
          {:ok, Result.t()} | {:error, Result.t()}
  def retry_step(issue, step, opts \\ [])

  def retry_step(issue, step, opts) when is_map(issue) and is_list(opts) do
    started_at = DateTime.utc_now()

    with {:ok, on_event} <- parse_on_event(Keyword.get(opts, :on_event, &default_on_event/1)),
         {:ok, attempt} <- parse_attempt(Keyword.get(opts, :attempt)),
         {:ok, issue_meta} <- issue_meta(issue),
         {:ok, config, prompt_template, run_settings_snapshot} <- resolve_workflow(issue, opts),
         {:ok, retry_step} <- parse_retry_step(step),
         {:ok, session_opts} <-
           normalize_opts(Keyword.get(opts, :session_opts, %{}), "session_opts"),
         {:ok, turn_opts} <- normalize_opts(Keyword.get(opts, :turn_opts, %{}), "turn_opts"),
         {:ok, workspace} <- resolve_retry_workspace(Keyword.get(opts, :workspace)) do
      config = with_agent_browser_defaults(config, workspace)
      log_files = Keyword.get(opts, :log_files)

      runtime = Runtime.init(runtime_kind(config), config, workspace)

      state = %{
        issue: issue,
        issue_id: issue_meta.id,
        identifier: issue_meta.identifier,
        started_at: started_at,
        workspace: workspace,
        runtime: runtime,
        session: nil,
        turn_count: 0,
        last_output: nil,
        events_rev: [],
        on_event: on_event,
        attempt: attempt,
        log_files: log_files
      }

      state =
        state
        |> emit(:run_started, %{
          attempt: attempt,
          mode: :step_retry,
          retry_step: retry_step,
          run_settings: run_settings_snapshot
        })
        |> emit(:workspace_ready, %{
          workspace_path: workspace.path,
          runtime_profile: runtime.profile
        })

      outcome =
        case run_retry_step_pipeline(
               state,
               config,
               prompt_template,
               retry_step,
               session_opts,
               turn_opts
             ) do
          {:ok, pipeline_state} ->
            {:ok, :ok, pipeline_state}

          {:error, reason, pipeline_state} ->
            {:error, reason, pipeline_state}
        end

      finalize_run_with_runtime(outcome, config)
    else
      {:error, reason} ->
        result = %Result{
          status: :failed,
          started_at: started_at,
          ended_at: DateTime.utc_now(),
          error: reason
        }

        {:error, result}
    end
  end

  def retry_step(_issue, _step, _opts) do
    started_at = DateTime.utc_now()

    result = %Result{
      status: :failed,
      started_at: started_at,
      ended_at: DateTime.utc_now(),
      error: "Issue must be a map and options must be a keyword list"
    }

    {:error, result}
  end

  defp run_retry_step_pipeline(
         state,
         config,
         _prompt_template,
         :checks,
         _session_opts,
         _turn_opts
       ) do
    with {:ok, state} <- run_required_checks(state, config),
         {:ok, state} <- run_review_if_enabled(state, config, 1),
         {:ok, state} <- ensure_runtime_if_needed(state, config),
         {:ok, state} <- run_testing_if_enabled(state, config, 1),
         {:ok, state} <- run_publish(state, config) do
      {:ok, state}
    else
      {:checks_failed, reason, state} -> {:error, reason, state}
      {:review_failed, reason, state} -> {:error, reason, state}
      {:testing_failed, reason, state} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp run_retry_step_pipeline(
         state,
         config,
         _prompt_template,
         :review,
         _session_opts,
         _turn_opts
       ) do
    with {:ok, state} <- run_review_if_enabled(state, config, 1),
         {:ok, state} <- ensure_runtime_if_needed(state, config),
         {:ok, state} <- run_testing_if_enabled(state, config, 1),
         {:ok, state} <- run_publish(state, config) do
      {:ok, state}
    else
      {:review_failed, reason, state} -> {:error, reason, state}
      {:testing_failed, reason, state} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp run_retry_step_pipeline(
         state,
         config,
         _prompt_template,
         :testing,
         _session_opts,
         _turn_opts
       ) do
    with {:ok, state} <- ensure_runtime_if_needed(state, config),
         {:ok, state} <- run_testing_if_enabled(state, config, 1),
         {:ok, state} <- run_publish(state, config) do
      {:ok, state}
    else
      {:testing_failed, reason, state} -> {:error, reason, state}
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp run_retry_step_pipeline(
         state,
         config,
         _prompt_template,
         :publish,
         _session_opts,
         _turn_opts
       ) do
    case run_publish(state, config) do
      {:ok, state} -> {:ok, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  @doc """
  Merges a pending_merge story's branch into base and marks it merged.

  Used for local provider stories that paused at pending_merge (because
  preview is enabled) and the operator now approves the merge.
  """
  @spec merge_pending_story(Config.t(), map(), Workspace.t()) :: :ok | {:error, String.t()}
  def merge_pending_story(config, issue, workspace) do
    base_branch = get_in(config, [Access.key(:git, %{}), Access.key(:base_branch)]) || "main"
    issue_id = Map.get(issue, :id) || Map.get(issue, "id")

    case Workspace.merge_branch_to_main(workspace, base_branch) do
      :ok ->
        tracker = tracker_module(config)

        case tracker.mark_merged(config, issue_id, %{
               branch: workspace.branch,
               base_branch: base_branch
             }) do
          :ok -> :ok
          {:error, reason} -> {:error, "merged but failed to update tracker: #{reason}"}
        end

      {:error, reason} ->
        {:error, "merge failed: #{reason}"}
    end
  end

  defp resolve_retry_workspace(%Workspace{} = workspace), do: {:ok, workspace}
  defp resolve_retry_workspace(_workspace), do: {:error, "workspace is required for step retries"}

  defp run_with_session(state, config, prompt_template, mode, turn_limit, session_opts, turn_opts) do
    case Agent.start_session(config, state.workspace, session_opts) do
      {:ok, session} ->
        state =
          state
          |> Map.put(:session, session)
          |> emit(:session_started, %{session_id: session.id, adapter: session.adapter})

        run_result =
          run_turns(state, config, prompt_template, mode, turn_limit, turn_opts)

        {status, reason, run_state} = normalize_run_result(run_result)

        outcome =
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              if is_nil(reason) do
                case finalize_with_quality_gates(
                       stopped_state,
                       config,
                       status,
                       session_opts,
                       turn_opts,
                       prompt_template
                     ) do
                  {:ok, qualified_state} ->
                    case run_publish(qualified_state, config) do
                      {:ok, published_state} ->
                        {:ok, status, published_state}

                      {:error, pub_reason, published_state} ->
                        {:error, pub_reason, published_state}
                    end

                  {:error, gate_reason, qualified_state} ->
                    {:error, gate_reason, qualified_state}
                end
              else
                {:error, reason, stopped_state}
              end

            {:error, stop_reason, stopped_state} ->
              combined_reason =
                combine_errors(reason, "Failed to stop agent session: #{stop_reason}")

              {:error, combined_reason, stopped_state}
          end

        finalize_run_with_runtime(outcome, config)

      {:error, reason} ->
        fail(state, "Failed to start agent session: #{reason}")
    end
  end

  defp finalize_run_with_runtime({:ok, status, state}, config) do
    if should_handoff_to_preview?(state, config) do
      case handoff_runtime_to_preview(state, config) do
        {:ok, handoff_state} ->
          succeed(handoff_state, status)

        {:error, _reason} ->
          case maybe_stop_runtime(state) do
            {:ok, stopped_state} -> succeed(stopped_state, status)
            {:error, reason, stopped_state} -> fail(stopped_state, reason)
          end
      end
    else
      case maybe_stop_runtime(state) do
        {:ok, stopped_state} ->
          succeed(stopped_state, status)

        {:error, reason, stopped_state} ->
          fail(stopped_state, reason)
      end
    end
  end

  defp finalize_run_with_runtime({:error, reason, state}, _config) do
    case maybe_stop_runtime(state) do
      {:ok, stopped_state} ->
        fail(stopped_state, reason)

      {:error, runtime_reason, stopped_state} ->
        fail(stopped_state, merge_error_messages(reason, runtime_reason))
    end
  end

  defp run_turns(state, config, prompt_template, mode, turn_limit, turn_opts) do
    turn_number = state.turn_count + 1

    with {:ok, prompt} <- build_prompt(state, config, prompt_template, turn_number),
         :ok <- Workspace.before_run(state.workspace, config.hooks, state.runtime) do
      state =
        state
        |> Map.put(:turn_count, turn_number)
        |> maybe_emit_prompt(turn_number, :agent, prompt)
        |> emit(:turn_started, %{turn: turn_number})

      turn_result =
        Agent.run_turn(
          state.session,
          prompt,
          with_raw_log(turn_opts, state.log_files, :agent_stdout)
        )

      Workspace.after_run(state.workspace, config.hooks)

      case turn_result do
        {:ok, result} ->
          turn_output = Map.get(result, :raw_output) || Map.get(result, :output)

          state =
            state
            |> Map.put(:last_output, result.output)
            |> emit(:turn_succeeded, %{
              turn: turn_number,
              duration_ms: result.duration_ms,
              output: turn_output,
              command: Map.get(result, :command),
              args: Map.get(result, :args, [])
            })

          continue_or_finish(state, config, prompt_template, mode, turn_limit, turn_opts)

        {:error, reason} ->
          state = emit(state, :turn_failed, %{turn: turn_number, reason: reason})
          {:error, reason, state}
      end
    else
      {:error, reason} ->
        state = emit(state, :turn_failed, %{turn: turn_number, reason: reason})
        {:error, reason, state}
    end
  end

  defp continue_or_finish(state, _config, _template, :single_turn, _turn_limit, _turn_opts) do
    {:ok, :ok, state}
  end

  defp continue_or_finish(state, _config, _template, :max_turns, turn_limit, _turn_opts)
       when state.turn_count >= turn_limit do
    {:ok, :max_turns_reached, state}
  end

  defp continue_or_finish(state, config, template, :max_turns, turn_limit, turn_opts) do
    run_turns(state, config, template, :max_turns, turn_limit, turn_opts)
  end

  defp build_prompt(state, config, prompt_template, 1) do
    variables = prompt_variables(state.issue, state.attempt, include_failure_context: true)
    resume_context = build_resume_context(state.workspace, Map.get(state, :continuation))

    variables =
      if resume_context == "",
        do: variables,
        else: Map.put(variables, "resume_context", resume_context)

    case build_task_prompt(prompt_template, variables, config) do
      {:ok, prompt} -> {:ok, append_context_if_missing(prompt, resume_context)}
      {:error, reason} -> {:error, "Failed to render initial prompt: #{reason}"}
    end
  end

  defp build_prompt(state, _config, _prompt_template, turn_number) do
    {:ok, ContinuationPrompt.build(state.issue, turn_number)}
  end

  defp build_task_prompt(prompt_template, variables, config) do
    case PromptBuilder.render(prompt_template, variables) do
      {:ok, prompt} -> {:ok, prompt <> verification_section(config)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verification_section(config) do
    commands =
      config
      |> checks_config()
      |> Map.get(:required, [])

    case commands do
      [] ->
        ""

      cmds ->
        list = Enum.map_join(cmds, "\n", fn cmd -> "- `#{cmd}`" end)

        "\n\n## Verification\n\nRun these commands to verify your changes before finishing:\n#{list}"
    end
  end

  defp build_resume_context(workspace, continuation) do
    workspace_resume_context = detect_resume_context(workspace)
    continuation_context = continuation_context(continuation)

    [workspace_resume_context, continuation_context]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp continuation_context(nil), do: ""

  defp continuation_context(continuation) when is_map(continuation) do
    originating_attempt = field(continuation, :originating_attempt)
    last_successful_turn = field(continuation, :last_successful_turn)
    failure_reason = field(continuation, :failure_reason)
    originating_session_id = field(continuation, :originating_session_id)
    mode = continuation_mode(field(continuation, :mode))

    """
    CONTINUATION CONTEXT: This run is an agent-phase continuation retry.

    - Retry mode: #{mode}
    - Originating run attempt: #{continuation_display_value(originating_attempt)}
    - Last successful turn: #{continuation_display_value(last_successful_turn)}
    - Failure reason: #{continuation_display_value(failure_reason)}
    - Originating session id: #{continuation_display_value(originating_session_id)}

    Continue from the latest completed state in this workspace. Do not restart from scratch.
    """
  end

  defp continuation_context(_continuation), do: ""

  defp continuation_display_value(value) when is_binary(value) and value != "", do: value
  defp continuation_display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp continuation_display_value(_value), do: "unknown"

  defp continuation_mode(value) when value in ["agent_continuation", "agent-continuation"],
    do: "agent_continuation"

  defp continuation_mode(value) when value in [:agent_continuation], do: "agent_continuation"
  defp continuation_mode(_value), do: "agent_continuation"

  defp append_context_if_missing(prompt, "") when is_binary(prompt), do: prompt

  defp append_context_if_missing(prompt, context) when is_binary(prompt) and is_binary(context) do
    if String.contains?(prompt, context) do
      prompt
    else
      prompt <> "\n\n" <> context
    end
  end

  defp append_context_if_missing(prompt, _context), do: prompt

  defp maybe_emit_continuation_context(state) when is_map(state) do
    case Map.get(state, :continuation) do
      nil ->
        state

      continuation when is_map(continuation) ->
        emit(state, :continuation_context_loaded, %{
          mode: continuation_mode(field(continuation, :mode)),
          originating_attempt: field(continuation, :originating_attempt),
          last_successful_turn: field(continuation, :last_successful_turn),
          failure_reason: field(continuation, :failure_reason),
          originating_session_id: field(continuation, :originating_session_id)
        })

      _other ->
        state
    end
  end

  defp maybe_emit_continuation_context(state), do: state

  defp maybe_emit_prompt(state, 1, phase, prompt) when is_binary(prompt) do
    emit(state, :prompt_captured, %{phase: phase, prompt: prompt})
  end

  defp maybe_emit_prompt(state, _cycle_or_turn, _phase, _prompt), do: state

  defp continuation_retry_mode(nil), do: :full_rerun
  defp continuation_retry_mode(%{}), do: :agent_continuation
  defp continuation_retry_mode(_), do: :full_rerun

  # Detect if there's existing work in the workspace to resume from
  defp detect_resume_context(nil), do: ""

  defp detect_resume_context(workspace) do
    workspace_path = Map.get(workspace, :path)

    if is_nil(workspace_path) or not File.dir?(workspace_path) do
      ""
    else
      # Check if worktree has commits ahead of main
      case System.cmd("git", ["-C", workspace_path, "rev-list", "--count", "main..HEAD"],
             stderr_to_stdout: true
           ) do
        {"0\n", 0} ->
          # No commits ahead of main
          ""

        {count_str, 0} ->
          count = String.trim(count_str) |> String.to_integer()

          if count > 0 do
            # Get list of changed files
            case System.cmd("git", ["-C", workspace_path, "diff", "--name-only", "main..HEAD"],
                   stderr_to_stdout: true
                 ) do
              {files_str, 0} ->
                files =
                  files_str |> String.trim() |> String.split("\n") |> Enum.reject(&(&1 == ""))

                if files != [] do
                  file_list = Enum.join(files, "\n  - ")

                  """

                  RESUME CONTEXT: You are continuing previous work. #{count} commit(s) ahead of main with the following changes:

                  Files created/modified:
                  - #{file_list}

                  DO NOT start over. Continue implementation from this checkpoint and complete the remaining work.
                  """
                else
                  ""
                end

              _ ->
                ""
            end
          else
            ""
          end

        _ ->
          # Not a git repo or other error
          ""
      end
    end
  end

  defp stop_session(state, session) do
    case Agent.stop_session(session) do
      :ok ->
        {:ok, emit(state, :session_stopped, %{session_id: session.id})}

      {:error, reason} ->
        stopped_state =
          emit(state, :session_stop_failed, %{session_id: session.id, reason: reason})

        {:error, reason, stopped_state}
    end
  end

  defp normalize_run_result({:ok, status, state}), do: {status, nil, state}
  defp normalize_run_result({:error, reason, state}), do: {:failed, reason, state}

  defp succeed(state, status) do
    state = emit(state, :run_finished, %{status: status})
    {:ok, result_from_state(state, status, nil)}
  end

  defp fail(state, reason) do
    state = emit(state, :run_finished, %{status: :failed, reason: reason})
    {:error, result_from_state(state, :failed, reason)}
  end

  defp run_publish(state, config) do
    workspace = state.workspace
    mode = Config.effective_publish_mode(config)
    provider = Config.effective_publish_provider(config)

    case Workspace.commits_ahead(workspace) do
      {:ok, :not_applicable} ->
        {:ok,
         emit(state, :publish_skipped, %{
           branch: workspace.branch,
           mode: mode,
           reason: "workspace strategy does not support publishing"
         })}

      {:ok, ahead} ->
        with :ok <- check_commit_requirement(mode, ahead) do
          state = emit(state, :publish_started, %{branch: workspace.branch, mode: mode})

          case mode do
            :push ->
              run_publish_push(state, workspace)

            :pr ->
              run_publish_pr(state, config, workspace, provider)

            :merge when provider in [:github, :gitlab] ->
              run_publish_merge_remote(state, config, workspace, provider)

            :merge ->
              run_publish_merge_local(state, config, workspace)
          end
        else
          {:error, reason} ->
            {:error, reason,
             emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
        end

      {:error, reason} ->
        {:error, reason,
         emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
    end
  end

  defp run_publish_push(state, workspace) do
    with {:ok, state} <- push_branch(state, workspace) do
      {:ok, emit(state, :publish_succeeded, %{branch: workspace.branch, pr_url: nil})}
    end
  end

  defp run_publish_pr(state, config, workspace, provider) do
    if provider in [:github, :gitlab] do
      run_publish_with_pr(state, config, workspace, provider, false)
    else
      {:error, "publish.mode pr requires provider github or gitlab (got: #{inspect(provider)})",
       emit(state, :publish_failed, %{branch: workspace.branch, reason: "unsupported provider"})}
    end
  end

  defp run_publish_merge_remote(state, config, workspace, provider) do
    run_publish_with_pr(state, config, workspace, provider, true)
  end

  defp run_publish_with_pr(state, config, workspace, provider, enable_auto_merge?) do
    pr_opts = Publisher.pr_opts(config, state.issue)

    with {:ok, pushed_state} <- push_branch(state, workspace) do
      with {:ok, adapter} <- publisher_adapter(provider),
           {:ok, pr_opts} <- require_pr_opts(pr_opts),
           {:ok, pr_url} <- create_pr(adapter, workspace, pr_opts),
           :ok <- maybe_enable_auto_merge(adapter, workspace, pr_url, enable_auto_merge?),
           :ok <- tracker_mark_pending_merge(config, pushed_state.issue_id, pr_url) do
        state =
          pushed_state
          |> emit(:publish_pr_created, %{branch: workspace.branch, pr_url: pr_url})
          |> emit(:publish_succeeded, %{branch: workspace.branch, pr_url: pr_url})

        {:ok, state}
      else
        {:error, reason} ->
          {:error, reason,
           emit(pushed_state, :publish_failed, %{branch: workspace.branch, reason: reason})}
      end
    else
      {:error, reason} ->
        {:error, reason,
         emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
    end
  end

  defp run_publish_merge_local(state, config, workspace) do
    if preview_enabled?(config) do
      run_publish_local_pending_merge(state, config, workspace)
    else
      run_publish_local_immediate_merge(state, config, workspace)
    end
  end

  defp run_publish_local_pending_merge(state, config, workspace) do
    with {:ok, pushed_state} <- push_branch(state, workspace) do
      case tracker_mark_pending_merge(config, pushed_state.issue_id, nil) do
        :ok ->
          state =
            pushed_state
            |> emit(:publish_pending_merge, %{
              branch: workspace.branch,
              reason: "preview enabled — awaiting manual merge"
            })
            |> emit(:publish_pr_created, %{branch: workspace.branch, pr_url: nil})
            |> emit(:publish_succeeded, %{branch: workspace.branch, pr_url: nil})

          {:ok, state}

        {:error, reason} ->
          {:error, reason,
           emit(pushed_state, :publish_failed, %{branch: workspace.branch, reason: reason})}
      end
    else
      {:error, reason} ->
        {:error, reason,
         emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
    end
  end

  defp run_publish_local_immediate_merge(state, config, workspace) do
    base_branch = get_in(config, [Access.key(:git, %{}), Access.key(:base_branch)]) || "main"

    with {:ok, pushed_state} <- push_branch(state, workspace) do
      case merge_branch_to_main(workspace, base_branch) do
        :ok ->
          case tracker_mark_merged(config, pushed_state.issue_id, workspace.branch, base_branch) do
            :ok ->
              state =
                pushed_state
                |> emit(:publish_merged, %{branch: workspace.branch, base_branch: base_branch})
                |> emit(:publish_succeeded, %{branch: workspace.branch, pr_url: nil})

              {:ok, state}

            {:error, reason} ->
              {:error, reason,
               emit(pushed_state, :publish_failed, %{branch: workspace.branch, reason: reason})}
          end

        {:error, {:merge_failed, reason}} ->
          if merge_conflict?(reason) do
            conflict_state =
              emit(pushed_state, :publish_merge_conflict, %{
                branch: workspace.branch,
                base_branch: base_branch,
                reason: reason
              })

            case schedule_conflict_remediation(conflict_state, config, reason) do
              {:ok, remediated_state} ->
                case tracker_mark_merged(
                       config,
                       remediated_state.issue_id,
                       workspace.branch,
                       base_branch
                     ) do
                  :ok ->
                    state =
                      remediated_state
                      |> emit(:publish_merged, %{
                        branch: workspace.branch,
                        base_branch: base_branch
                      })
                      |> emit(:publish_succeeded, %{branch: workspace.branch, pr_url: nil})

                    {:ok, state}

                  {:error, tracker_reason} ->
                    {:error, tracker_reason,
                     emit(remediated_state, :publish_failed, %{
                       branch: workspace.branch,
                       reason: tracker_reason
                     })}
                end

              {:error, remediation_reason, remediated_state} ->
                {:error, remediation_reason,
                 emit(remediated_state, :publish_failed, %{
                   branch: workspace.branch,
                   reason: remediation_reason
                 })}
            end
          else
            Logger.warning(
              "publish auto-merge failed for branch #{workspace.branch} -> #{base_branch}: #{reason}"
            )

            merged_state =
              emit(pushed_state, :publish_merge_failed, %{
                branch: workspace.branch,
                base_branch: base_branch,
                reason: reason
              })

            {:ok,
             emit(merged_state, :publish_succeeded, %{branch: workspace.branch, pr_url: nil})}
          end

        {:error, reason} ->
          {:error, reason,
           emit(pushed_state, :publish_failed, %{branch: workspace.branch, reason: reason})}
      end
    else
      {:error, reason} ->
        {:error, reason,
         emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
    end
  end

  defp push_branch(state, workspace) do
    case Workspace.push_branch(workspace) do
      :ok -> {:ok, emit(state, :publish_push_succeeded, %{branch: workspace.branch})}
      {:error, reason} -> {:error, "push failed: #{reason}"}
    end
  end

  defp merge_branch_to_main(workspace, base_branch) do
    case Workspace.merge_branch_to_main(workspace, base_branch) do
      :ok -> :ok
      {:error, reason} -> {:error, {:merge_failed, reason}}
    end
  end

  defp schedule_conflict_remediation(state, config, reason) do
    workspace = state.workspace
    base_branch = get_in(config, [Access.key(:git, %{}), Access.key(:base_branch)]) || "main"

    prompt = conflict_remediation_prompt(workspace.branch, reason)

    case run_conflict_remediation_turn(state, config, prompt, base_branch) do
      {:ok, remediated_state} ->
        case merge_branch_to_main(workspace, base_branch) do
          :ok ->
            {:ok,
             emit(remediated_state, :publish_merge_conflict_resolved, %{
               branch: workspace.branch,
               base_branch: base_branch
             })}

          {:error, {:merge_failed, retry_reason}} ->
            {:error,
             "conflict resolution failed: merge still conflicts after remediation: #{retry_reason}",
             remediated_state}

          {:error, retry_reason} ->
            {:error, "conflict resolution failed: #{retry_reason}", remediated_state}
        end

      {:error, remediation_reason, remediated_state} ->
        {:error, "conflict resolution failed: #{remediation_reason}", remediated_state}
    end
  end

  defp run_conflict_remediation_turn(state, config, prompt, base_branch) do
    with {:ok, session} <- Agent.start_session(config, state.workspace, %{}) do
      state =
        state
        |> Map.put(:session, session)
        |> emit(:session_started, %{
          session_id: session.id,
          adapter: session.adapter,
          remediation: true,
          remediation_type: :merge_conflict,
          base_branch: base_branch
        })

      turn_number = state.turn_count + 1

      run_result =
        with :ok <- Workspace.before_run(state.workspace, config.hooks, state.runtime) do
          state =
            state
            |> Map.put(:turn_count, turn_number)
            |> emit(:turn_started, %{
              turn: turn_number,
              remediation: true,
              remediation_type: :merge_conflict,
              base_branch: base_branch
            })

          turn_result =
            Agent.run_turn(
              session,
              prompt,
              with_raw_log(%{}, state.log_files, :agent_stdout)
            )

          Workspace.after_run(state.workspace, config.hooks)

          case turn_result do
            {:ok, result} ->
              turn_output = Map.get(result, :raw_output) || Map.get(result, :output)

              {:ok,
               state
               |> Map.put(:last_output, result.output)
               |> emit(:turn_succeeded, %{
                 turn: turn_number,
                 duration_ms: result.duration_ms,
                 remediation: true,
                 remediation_type: :merge_conflict,
                 base_branch: base_branch,
                 output: turn_output,
                 command: Map.get(result, :command),
                 args: Map.get(result, :args, [])
               })}

            {:error, reason} ->
              {:error, reason,
               emit(state, :turn_failed, %{
                 turn: turn_number,
                 reason: reason,
                 remediation: true,
                 remediation_type: :merge_conflict,
                 base_branch: base_branch
               })}
          end
        else
          {:error, reason} ->
            {:error, reason,
             emit(state, :turn_failed, %{
               turn: turn_number,
               reason: reason,
               remediation: true,
               remediation_type: :merge_conflict,
               base_branch: base_branch
             })}
        end

      case run_result do
        {:ok, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:ok, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, "Failed to stop agent session: #{stop_reason}", stopped_state}
          end

        {:error, reason, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:error, reason, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, combine_errors(reason, "Failed to stop agent session: #{stop_reason}"),
               stopped_state}
          end
      end
    else
      {:error, session_reason} ->
        {:error, "failed to run conflict remediation turn: #{session_reason}", state}
    end
  end

  defp conflict_remediation_prompt(branch, reason) do
    """
    The previous attempt to merge branch `#{branch}` into `main` failed with conflicts:

    #{reason}

    Please resolve the conflicts:
    1. `git fetch origin`
    2. `git rebase origin/main`
    3. Resolve any conflicts in conflicting files
    4. `git rebase --continue` or `git add . && git rebase --continue`
    5. `git push --force-with-lease origin #{branch}`
    """
  end

  defp merge_conflict?(reason) when is_binary(reason),
    do: String.contains?(reason, "CONFLICT") or String.contains?(reason, "conflict")

  defp merge_conflict?(_reason), do: false

  defp publisher_adapter(provider) do
    case Publisher.module_for_provider(provider) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_pr_opts(nil), do: {:error, "failed to build PR options for publish mode"}
  defp require_pr_opts(pr_opts), do: {:ok, pr_opts}

  defp create_pr(adapter, workspace, pr_opts) do
    case adapter.create_pr(workspace, pr_opts) do
      {:ok, url} when is_binary(url) and url != "" -> {:ok, url}
      {:ok, _other} -> {:error, "PR creation failed: adapter returned an empty URL"}
      {:error, reason} -> {:error, "PR creation failed: #{reason}"}
    end
  end

  defp maybe_enable_auto_merge(_adapter, _workspace, _pr_url, false), do: :ok

  defp maybe_enable_auto_merge(adapter, workspace, pr_url, true) do
    case adapter.enable_auto_merge(workspace, pr_url) do
      :ok -> :ok
      {:error, reason} -> {:error, "auto-merge enable failed: #{reason}"}
    end
  end

  defp tracker_mark_pending_merge(config, issue_id, pr_url) do
    tracker = tracker_module(config)

    case tracker.mark_pending_merge(config, issue_id, %{pr_url: pr_url}) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to mark issue pending_merge: #{reason}"}
      other -> {:error, "tracker mark_pending_merge returned invalid response: #{inspect(other)}"}
    end
  end

  defp tracker_mark_merged(config, issue_id, branch, base_branch) do
    tracker = tracker_module(config)

    metadata = %{branch: branch, base_branch: base_branch}

    case tracker.mark_merged(config, issue_id, metadata) do
      :ok -> :ok
      {:error, reason} -> {:error, "failed to mark issue merged: #{reason}"}
      other -> {:error, "tracker mark_merged returned invalid response: #{inspect(other)}"}
    end
  end

  defp tracker_module(config) do
    kind = get_in(config, [Access.key(:tracker, %{}), Access.key(:kind)])
    Tracker.module_for_kind(kind)
  end

  defp check_commit_requirement(_mode, ahead) when is_integer(ahead) and ahead > 0, do: :ok

  defp check_commit_requirement(_mode, 0) do
    {:error, "no commits found on branch — agent did not commit any changes"}
  end

  defp check_commit_requirement(mode, ahead) do
    {:error,
     "invalid publish precondition for mode #{inspect(mode)}: commits_ahead=#{inspect(ahead)}"}
  end

  defp finalize_with_quality_gates(
         state,
         config,
         _status,
         session_opts,
         turn_opts,
         prompt_template
       ) do
    quality_limit = quality_max_cycles(config)
    checks_limit = min(quality_limit, checks_max_cycles(config))
    review_limit = min(quality_limit, review_max_cycles(config))
    testing_limit = min(quality_limit, testing_max_cycles(config))

    run_quality_cycle(
      state,
      config,
      session_opts,
      turn_opts,
      prompt_template,
      1,
      quality_limit,
      checks_limit,
      review_limit,
      testing_limit
    )
  end

  defp run_quality_cycle(
         state,
         config,
         session_opts,
         turn_opts,
         prompt_template,
         cycle,
         quality_limit,
         checks_limit,
         review_limit,
         testing_limit
       ) do
    state =
      emit(state, :quality_cycle_started, %{
        cycle: cycle,
        max_cycles: quality_limit,
        checks_max_cycles: checks_limit,
        review_max_cycles: review_limit,
        testing_max_cycles: testing_limit
      })

    with {:ok, state} <- run_required_checks(state, config),
         {:ok, state} <- run_review_if_enabled(state, config, cycle),
         {:ok, state} <- ensure_runtime_if_needed(state, config),
         {:ok, state} <- run_testing_if_enabled(state, config, cycle) do
      {:ok, emit(state, :quality_cycle_passed, %{cycle: cycle})}
    else
      {:checks_failed, reason, state} when cycle < checks_limit ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: quality_limit,
            checks_max_cycles: checks_limit,
            review_max_cycles: review_limit,
            testing_max_cycles: testing_limit,
            retry_reason: reason,
            retry_type: :checks
          })

        case run_checks_remediation_turn(
               state,
               config,
               reason,
               cycle,
               session_opts,
               turn_opts,
               prompt_template
             ) do
          {:ok, state} ->
            run_quality_cycle(
              state,
              config,
              session_opts,
              turn_opts,
              prompt_template,
              cycle + 1,
              quality_limit,
              checks_limit,
              review_limit,
              testing_limit
            )

          {:error, remediation_reason, state} ->
            {:error, "checks remediation failed: #{remediation_reason}", state}
        end

      {:checks_failed, reason, state} ->
        {:error, "checks failed after #{checks_limit} cycle(s): #{reason}", state}

      {:review_failed, reason, state} when cycle < review_limit ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: quality_limit,
            checks_max_cycles: checks_limit,
            review_max_cycles: review_limit,
            testing_max_cycles: testing_limit,
            retry_reason: reason,
            retry_type: :review
          })

        case run_review_remediation_turn(
               state,
               config,
               reason,
               cycle,
               session_opts,
               turn_opts,
               prompt_template
             ) do
          {:ok, state} ->
            run_quality_cycle(
              state,
              config,
              session_opts,
              turn_opts,
              prompt_template,
              cycle + 1,
              quality_limit,
              checks_limit,
              review_limit,
              testing_limit
            )

          {:error, remediation_reason, state} ->
            {:error, "review remediation failed: #{remediation_reason}", state}
        end

      {:review_failed, reason, state} ->
        {:error, "review failed after #{review_limit} cycle(s): #{reason}", state}

      {:testing_failed, reason, state} when cycle < testing_limit ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: quality_limit,
            checks_max_cycles: checks_limit,
            review_max_cycles: review_limit,
            testing_max_cycles: testing_limit,
            retry_reason: reason,
            retry_type: :testing
          })

        case run_testing_remediation_turn(
               state,
               config,
               reason,
               cycle,
               session_opts,
               turn_opts,
               prompt_template
             ) do
          {:ok, state} ->
            run_quality_cycle(
              state,
              config,
              session_opts,
              turn_opts,
              prompt_template,
              cycle + 1,
              quality_limit,
              checks_limit,
              review_limit,
              testing_limit
            )

          {:error, remediation_reason, state} ->
            {:error, "testing remediation failed: #{remediation_reason}", state}
        end

      {:testing_failed, reason, state} ->
        {:error, "testing failed after #{testing_limit} cycle(s): #{reason}", state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  defp run_required_checks(state, config) do
    commands = required_check_commands(config)

    if commands == [] do
      {:ok, state}
    else
      case workspace_path(state.workspace) do
        nil ->
          {:error, "required checks failed: workspace path is unavailable", state}

        workspace_path ->
          with {:ok, state} <- ensure_runtime_for_checks(state) do
            timeout_ms = checks_timeout_ms(config)
            fail_fast = checks_fail_fast?(config)

            state =
              emit(state, :checks_started, %{
                check_count: length(commands),
                timeout_ms: timeout_ms,
                fail_fast: fail_fast,
                runtime_profile: runtime_profile_from_state(state)
              })

            {state, errors} =
              commands
              |> Enum.with_index(1)
              |> Enum.reduce({state, []}, fn {command, index}, {acc_state, acc_errors} ->
                if fail_fast and acc_errors != [] do
                  {acc_state, acc_errors}
                else
                  acc_state =
                    emit(acc_state, :check_started, %{check_index: index, command: command})

                  case execute_check_command(
                         workspace_path,
                         command,
                         timeout_ms,
                         acc_state.runtime
                       ) do
                    {:ok, duration_ms, output} ->
                      {
                        emit(acc_state, :check_passed, %{
                          check_index: index,
                          command: command,
                          duration_ms: duration_ms,
                          output: output
                        }),
                        acc_errors
                      }

                    {:error, reason, duration_ms, output} ->
                      output_preview = output_preview(output)

                      error_message =
                        "check ##{index} failed (#{command}): #{reason}#{preview_suffix(output_preview)}"

                      {
                        emit(acc_state, :check_failed, %{
                          check_index: index,
                          command: command,
                          reason: reason,
                          duration_ms: duration_ms,
                          output: output,
                          output_preview: output_preview
                        }),
                        acc_errors ++ [error_message]
                      }
                  end
                end
              end)

            if errors == [] do
              {:ok, emit(state, :checks_passed, %{check_count: length(commands)})}
            else
              reason = "required checks failed:\n#{Enum.map_join(errors, "\n", &"- #{&1}")}"

              {:checks_failed, reason,
               emit(state, :checks_failed, %{error_count: length(errors)})}
            end
          else
            {:error, reason, state} ->
              {:error, reason, state}
          end
      end
    end
  end

  defp run_review_if_enabled(state, config, cycle) do
    if review_enabled?(config) do
      review_agent_kind = review_agent_kind(config)
      state = emit(state, :review_started, %{agent_kind: review_agent_kind, cycle: cycle})

      # Write review.json inside the workspace worktree — the reviewer agent
      # has full write access there. The orchestrator copies it to the
      # attempt dir afterward for persistence/UI access.
      workspace_rjp = workspace_review_json_path(state.workspace)

      with :ok <- reset_review_json(workspace_rjp),
           {:ok, prompt} <- build_review_prompt(state, config, cycle, workspace_rjp),
           state = maybe_emit_prompt(state, cycle, :review, prompt),
           {:ok, _output} <- run_review_turn(state, config, prompt, state.log_files) do
        persist_review_json(workspace_rjp, state.log_files)
        persist_review_cycle_json(workspace_rjp, state.log_files, cycle)

        case read_review_json(workspace_rjp) do
          {:ok, :pass} ->
            {:ok, emit(state, :review_passed, %{agent_kind: review_agent_kind, cycle: cycle})}

          {:ok, {:fail, feedback}} ->
            {:review_failed, feedback,
             emit(state, :review_failed, %{
               agent_kind: review_agent_kind,
               cycle: cycle,
               reason: feedback
             })}

          {:review_failed, feedback} ->
            {:review_failed, feedback,
             emit(state, :review_failed, %{
               agent_kind: review_agent_kind,
               cycle: cycle,
               reason: feedback
             })}

          {:error, reason} ->
            {:error, "review failed: #{reason}",
             emit(state, :review_error, %{
               agent_kind: review_agent_kind,
               cycle: cycle,
               reason: reason
             })}
        end
      else
        {:error, reason} ->
          {:error, "review failed: #{reason}",
           emit(state, :review_error, %{
             agent_kind: review_agent_kind,
             cycle: cycle,
             reason: reason
           })}
      end
    else
      {:ok, state}
    end
  end

  defp run_testing_if_enabled(state, config, cycle) do
    if testing_enabled?(config) do
      testing_agent_kind = testing_agent_kind(config)

      state =
        emit(state, :testing_started, %{
          agent_kind: testing_agent_kind,
          cycle: cycle,
          runtime_profile: runtime_profile_from_state(state)
        })

      workspace_tjp = workspace_testing_json_path(state.workspace)

      with :ok <- reset_testing_json(workspace_tjp),
           {:ok, prompt} <- build_testing_prompt(state, config, cycle, workspace_tjp),
           state = maybe_emit_prompt(state, cycle, :testing, prompt),
           {:ok, testing_run} <- run_testing_turn(state, config, prompt, state.log_files) do
        persist_testing_json(workspace_tjp, state.log_files)
        persist_testing_cycle_json(workspace_tjp, state.log_files, cycle)

        case read_testing_json(workspace_tjp) do
          {:ok, %{verdict: :pass} = testing} ->
            testing = persist_testing_report(testing, state.workspace, state.log_files)
            persist_testing_cycle_report(testing, state.log_files, cycle)
            state = emit_testing_checkpoints(state, testing.checkpoints, cycle)

            {:ok,
             emit(state, :testing_passed, %{
               agent_kind: testing_agent_kind,
               cycle: cycle,
               summary: testing.summary,
               checkpoint_count: length(testing.checkpoints),
               artifact_count: length(testing.artifacts),
               duration_ms: testing_run.duration_ms,
               command: testing_run.command,
               args: testing_run.args,
               output: testing_run.output
             })}

          {:ok, %{verdict: :fail} = testing} ->
            testing = persist_testing_report(testing, state.workspace, state.log_files)
            persist_testing_cycle_report(testing, state.log_files, cycle)
            state = emit_testing_checkpoints(state, testing.checkpoints, cycle)

            {:testing_failed, testing.feedback,
             emit(state, :testing_failed, %{
               agent_kind: testing_agent_kind,
               cycle: cycle,
               reason: testing.feedback,
               summary: testing.summary,
               checkpoint_count: length(testing.checkpoints),
               artifact_count: length(testing.artifacts),
               duration_ms: testing_run.duration_ms,
               command: testing_run.command,
               args: testing_run.args,
               output: testing_run.output
             })}

          {:testing_failed, feedback} ->
            {:testing_failed, feedback,
             emit(state, :testing_failed, %{
               agent_kind: testing_agent_kind,
               cycle: cycle,
               reason: feedback
             })}

          {:error, reason} ->
            {:error, "testing failed: #{reason}",
             emit(state, :testing_error, %{
               agent_kind: testing_agent_kind,
               cycle: cycle,
               reason: reason
             })}
        end
      else
        {:error, reason, state} ->
          {:error, reason,
           emit(state, :testing_error, %{
             agent_kind: testing_agent_kind,
             cycle: cycle,
             reason: reason
           })}

        {:error, reason} ->
          {:error, "testing failed: #{reason}",
           emit(state, :testing_error, %{
             agent_kind: testing_agent_kind,
             cycle: cycle,
             reason: reason
           })}
      end
    else
      {:ok, state}
    end
  end

  defp emit_testing_checkpoints(state, checkpoints, cycle) when is_list(checkpoints) do
    total = length(checkpoints)

    checkpoints
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {checkpoint, index}, acc ->
      emit(acc, :testing_checkpoint, %{
        cycle: cycle,
        checkpoint_index: index,
        checkpoint_count: total,
        name: Map.get(checkpoint, :name),
        status: Map.get(checkpoint, :status),
        details: Map.get(checkpoint, :details)
      })
    end)
  end

  defp emit_testing_checkpoints(state, _checkpoints, _cycle), do: state

  defp run_review_remediation_turn(
         state,
         config,
         review_feedback,
         cycle,
         session_opts,
         turn_opts,
         prompt_template
       ) do
    with {:ok, prompt} <-
           build_review_remediation_prompt(state, review_feedback, cycle, prompt_template),
         {:ok, session} <- Agent.start_session(config, state.workspace, session_opts) do
      state =
        state
        |> Map.put(:session, session)
        |> emit(:session_started, %{
          session_id: session.id,
          adapter: session.adapter,
          remediation: true,
          review_cycle: cycle
        })

      turn_number = state.turn_count + 1

      run_result =
        with :ok <- Workspace.before_run(state.workspace, config.hooks, state.runtime) do
          state =
            state
            |> Map.put(:turn_count, turn_number)
            |> emit(:turn_started, %{turn: turn_number, remediation: true, review_cycle: cycle})

          turn_result =
            Agent.run_turn(
              session,
              prompt,
              with_raw_log(turn_opts, state.log_files, :agent_stdout)
            )

          Workspace.after_run(state.workspace, config.hooks)

          case turn_result do
            {:ok, result} ->
              turn_output = Map.get(result, :raw_output) || Map.get(result, :output)

              {:ok,
               state
               |> Map.put(:last_output, result.output)
               |> emit(:turn_succeeded, %{
                 turn: turn_number,
                 duration_ms: result.duration_ms,
                 remediation: true,
                 review_cycle: cycle,
                 output: turn_output,
                 command: Map.get(result, :command),
                 args: Map.get(result, :args, [])
               })}

            {:error, reason} ->
              {:error, reason,
               emit(state, :turn_failed, %{
                 turn: turn_number,
                 reason: reason,
                 remediation: true,
                 review_cycle: cycle
               })}
          end
        else
          {:error, reason} ->
            {:error, reason,
             emit(state, :turn_failed, %{
               turn: turn_number,
               reason: reason,
               remediation: true,
               review_cycle: cycle
             })}
        end

      case run_result do
        {:ok, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:ok, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, "Failed to stop agent session: #{stop_reason}", stopped_state}
          end

        {:error, reason, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:error, reason, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, combine_errors(reason, "Failed to stop agent session: #{stop_reason}"),
               stopped_state}
          end
      end
    else
      {:error, reason} ->
        {:error, "failed to run review remediation turn: #{reason}", state}
    end
  end

  defp run_testing_remediation_turn(
         state,
         config,
         testing_feedback,
         cycle,
         session_opts,
         turn_opts,
         prompt_template
       ) do
    with {:ok, prompt} <-
           build_testing_remediation_prompt(state, testing_feedback, cycle, prompt_template),
         {:ok, session} <- Agent.start_session(config, state.workspace, session_opts) do
      state =
        state
        |> Map.put(:session, session)
        |> emit(:session_started, %{
          session_id: session.id,
          adapter: session.adapter,
          remediation: true,
          testing_cycle: cycle
        })

      turn_number = state.turn_count + 1

      run_result =
        with :ok <- Workspace.before_run(state.workspace, config.hooks, state.runtime) do
          state =
            state
            |> Map.put(:turn_count, turn_number)
            |> emit(:turn_started, %{turn: turn_number, remediation: true, testing_cycle: cycle})

          turn_result =
            Agent.run_turn(
              session,
              prompt,
              with_raw_log(turn_opts, state.log_files, :agent_stdout)
            )

          Workspace.after_run(state.workspace, config.hooks)

          case turn_result do
            {:ok, result} ->
              turn_output = Map.get(result, :raw_output) || Map.get(result, :output)

              {:ok,
               state
               |> Map.put(:last_output, result.output)
               |> emit(:turn_succeeded, %{
                 turn: turn_number,
                 duration_ms: result.duration_ms,
                 remediation: true,
                 testing_cycle: cycle,
                 output: turn_output,
                 command: Map.get(result, :command),
                 args: Map.get(result, :args, [])
               })}

            {:error, reason} ->
              {:error, reason,
               emit(state, :turn_failed, %{
                 turn: turn_number,
                 reason: reason,
                 remediation: true,
                 testing_cycle: cycle
               })}
          end
        else
          {:error, reason} ->
            {:error, reason,
             emit(state, :turn_failed, %{
               turn: turn_number,
               reason: reason,
               remediation: true,
               testing_cycle: cycle
             })}
        end

      case run_result do
        {:ok, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:ok, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, "Failed to stop agent session: #{stop_reason}", stopped_state}
          end

        {:error, reason, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:error, reason, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, combine_errors(reason, "Failed to stop agent session: #{stop_reason}"),
               stopped_state}
          end
      end
    else
      {:error, reason} ->
        {:error, "failed to run testing remediation turn: #{reason}", state}
    end
  end

  defp run_checks_remediation_turn(
         state,
         config,
         checks_feedback,
         cycle,
         session_opts,
         turn_opts,
         prompt_template
       ) do
    with {:ok, prompt} <-
           build_checks_remediation_prompt(state, checks_feedback, cycle, prompt_template),
         {:ok, session} <- Agent.start_session(config, state.workspace, session_opts) do
      state =
        state
        |> Map.put(:session, session)
        |> emit(:session_started, %{
          session_id: session.id,
          adapter: session.adapter,
          remediation: true,
          checks_cycle: cycle
        })

      turn_number = state.turn_count + 1

      run_result =
        with :ok <- Workspace.before_run(state.workspace, config.hooks, state.runtime) do
          state =
            state
            |> Map.put(:turn_count, turn_number)
            |> emit(:turn_started, %{turn: turn_number, remediation: true, checks_cycle: cycle})

          turn_result =
            Agent.run_turn(
              session,
              prompt,
              with_raw_log(turn_opts, state.log_files, :agent_stdout)
            )

          Workspace.after_run(state.workspace, config.hooks)

          case turn_result do
            {:ok, result} ->
              turn_output = Map.get(result, :raw_output) || Map.get(result, :output)

              {:ok,
               state
               |> Map.put(:last_output, result.output)
               |> emit(:turn_succeeded, %{
                 turn: turn_number,
                 duration_ms: result.duration_ms,
                 remediation: true,
                 checks_cycle: cycle,
                 output: turn_output,
                 command: Map.get(result, :command),
                 args: Map.get(result, :args, [])
               })}

            {:error, reason} ->
              {:error, reason,
               emit(state, :turn_failed, %{
                 turn: turn_number,
                 reason: reason,
                 remediation: true,
                 checks_cycle: cycle
               })}
          end
        else
          {:error, reason} ->
            {:error, reason,
             emit(state, :turn_failed, %{
               turn: turn_number,
               reason: reason,
               remediation: true,
               checks_cycle: cycle
             })}
        end

      case run_result do
        {:ok, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:ok, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, "Failed to stop agent session: #{stop_reason}", stopped_state}
          end

        {:error, reason, run_state} ->
          case stop_session(run_state, session) do
            {:ok, stopped_state} ->
              {:error, reason, stopped_state}

            {:error, stop_reason, stopped_state} ->
              {:error, combine_errors(reason, "Failed to stop agent session: #{stop_reason}"),
               stopped_state}
          end
      end
    else
      {:error, reason} ->
        {:error, "failed to run checks remediation turn: #{reason}", state}
    end
  end

  defp build_checks_remediation_prompt(state, checks_feedback, cycle, prompt_template) do
    base_variables = prompt_variables(state.issue, state.attempt, include_failure_context: true)

    base_prompt =
      case PromptBuilder.render(prompt_template, base_variables) do
        {:ok, prompt} -> prompt
        {:error, _reason} -> ""
      end

    remediation_template =
      """
      Continue working on issue {{ issue.identifier }}: {{ issue.title }}.

      Previous assignment:
      {{ base_prompt }}

      The following required checks failed (cycle {{ cycle }}):
      {{ checks_feedback }}

      Fix all check failures. Do not modify check configurations or disable checks — fix the underlying code so that all checks pass.
      """

    variables =
      base_variables
      |> Map.put("checks_feedback", checks_feedback)
      |> Map.put("cycle", cycle)
      |> Map.put("base_prompt", base_prompt)

    case PromptBuilder.render(remediation_template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render checks remediation prompt: #{reason}"}
    end
  end

  defp execute_check_command(_workspace_path, command, timeout_ms, runtime) do
    case Runtime.exec(runtime, command, timeout_ms) do
      {:ok, output, duration_ms} ->
        {:ok, duration_ms, output}

      {:error, reason, output, duration_ms} ->
        {:error, reason, duration_ms, output}
    end
  end

  defp ensure_runtime_for_checks(state), do: {:ok, state}

  defp ensure_runtime_if_needed(state, config) do
    if testing_enabled?(config) do
      ensure_runtime_for_testing(state)
    else
      {:ok, state}
    end
  end

  defp ensure_runtime_for_testing(state) do
    runtime = state.runtime

    with {:ok, state} <- ensure_runtime_started_for_testing(state, runtime),
         {:ok, state} <- ensure_runtime_healthcheck(state) do
      {:ok, state}
    end
  end

  defp ensure_runtime_started_for_testing(state, runtime) do
    cond do
      runtime.started? ->
        {:ok, state}

      not runtime_processes_configured?(runtime) ->
        {:error, "testing requires runtime.processes to be configured", state}

      true ->
        start_runtime(state)
    end
  end

  defp ensure_runtime_healthcheck(state) do
    runtime = state.runtime

    state =
      emit(state, :runtime_healthcheck_started, %{
        runtime_profile: runtime.profile,
        workspace_path: runtime.workspace_path,
        command: runtime.command,
        timeout_ms: runtime.start_timeout_ms,
        resolved_ports: runtime.resolved_ports
      })

    case Runtime.healthcheck(runtime) do
      :ok ->
        {:ok,
         emit(state, :runtime_healthcheck_passed, %{
           runtime_profile: runtime.profile,
           workspace_path: runtime.workspace_path,
           command: runtime.command,
           resolved_ports: runtime.resolved_ports
         })}

      {:error, reason} ->
        {:error, "runtime healthcheck failed: #{reason}",
         emit(state, :runtime_healthcheck_failed, %{
           runtime_profile: runtime.profile,
           workspace_path: runtime.workspace_path,
           command: runtime.command,
           reason: reason,
           resolved_ports: runtime.resolved_ports
         })}
    end
  end

  defp start_runtime(state) do
    runtime = state.runtime

    state =
      emit(state, :runtime_starting, %{
        runtime_profile: runtime.profile,
        command: runtime.command,
        workspace_path: runtime.workspace_path,
        process_count: length(runtime.processes)
      })

    case Runtime.start(runtime) do
      {:ok, runtime} ->
        state =
          state
          |> Map.put(:runtime, runtime)
          |> emit(:runtime_started, %{
            runtime_profile: runtime.profile,
            workspace_path: runtime.workspace_path,
            command: runtime.command,
            process_count: length(runtime.processes),
            port_offset: runtime.port_offset,
            resolved_ports: runtime.resolved_ports
          })

        {:ok, state}

      {:error, reason, runtime} ->
        state =
          state
          |> Map.put(:runtime, runtime)
          |> emit(:runtime_start_failed, %{
            runtime_profile: runtime.profile,
            workspace_path: runtime.workspace_path,
            command: runtime.command,
            reason: reason
          })

        {:error, reason, state}
    end
  end

  defp maybe_stop_runtime(state) do
    runtime = state.runtime

    if runtime.profile == :checks_only or not runtime_needs_stop?(runtime) do
      runtime = Runtime.release(runtime)
      {:ok, Map.put(state, :runtime, runtime)}
    else
      state =
        emit(state, :runtime_stopping, %{
          runtime_profile: runtime.profile,
          command: runtime.command,
          workspace_path: runtime.workspace_path
        })

      case Runtime.stop(runtime) do
        {:ok, runtime} ->
          state =
            state
            |> Map.put(:runtime, runtime)
            |> emit(:runtime_stopped, %{
              runtime_profile: runtime.profile,
              workspace_path: runtime.workspace_path,
              command: runtime.command
            })

          {:ok, state}

        {:error, reason, runtime} ->
          state =
            state
            |> Map.put(:runtime, runtime)
            |> emit(:runtime_stop_failed, %{
              runtime_profile: runtime.profile,
              workspace_path: runtime.workspace_path,
              command: runtime.command,
              reason: reason
            })

          {:error, reason, state}
      end
    end
  end

  defp runtime_needs_stop?(runtime) do
    runtime.started? == true or runtime.process_state == :start_failed
  end

  defp runtime_profile_from_state(state) do
    state
    |> Map.get(:runtime, %{})
    |> Map.get(:profile, :full_stack)
  end

  defp runtime_processes_configured?(runtime) do
    runtime
    |> Map.get(:processes, [])
    |> case do
      processes when is_list(processes) -> processes != []
      _other -> false
    end
  end

  defp runtime_kind(config) do
    config
    |> Map.get(:runtime, %{})
    |> Map.get(:kind, :host)
  end

  defp preview_enabled?(config) do
    get_in(config, [Access.key(:preview, %{}), Access.key(:enabled, false)]) == true
  end

  defp preview_reuse_testing_runtime?(config) do
    preview_enabled?(config) and
      get_in(config, [Access.key(:preview, %{}), Access.key(:reuse_testing_runtime, true)]) ==
        true
  end

  defp should_handoff_to_preview?(state, config) do
    preview_reuse_testing_runtime?(config) and
      runtime_needs_stop?(state.runtime) and
      run_entered_pending_merge?(state)
  end

  defp run_entered_pending_merge?(state) do
    state.events_rev
    |> Enum.any?(fn event ->
      type = Map.get(event, :type) || Map.get(event, "type")

      type in [
        :publish_pr_created,
        "publish_pr_created",
        :publish_pending_merge,
        "publish_pending_merge"
      ]
    end)
  end

  defp handoff_runtime_to_preview(state, config) do
    alias Kollywood.PreviewSessionManager

    project_slug = tracker_project_slug(config)
    story_id = state.issue_id

    ttl_minutes =
      get_in(config, [Access.key(:preview, %{}), Access.key(:ttl_minutes, 120)]) || 120

    state_with_event =
      emit(state, :preview_runtime_handoff, %{
        story_id: story_id,
        project: project_slug,
        runtime_kind: state.runtime.kind
      })

    case PreviewSessionManager.handoff_runtime(project_slug, story_id, state.runtime,
           ttl_minutes: ttl_minutes
         ) do
      {:ok, _session} ->
        runtime = %{
          state.runtime
          | offset_lease_name: nil,
            started?: false,
            process_state: :handed_off
        }

        {:ok, Map.put(state_with_event, :runtime, runtime)}

      {:error, reason} ->
        Logger.warning("Preview handoff failed for #{story_id}: #{reason}")
        {:error, reason}
    end
  end

  defp tracker_project_slug(config) do
    get_in(config, [Access.key(:tracker, %{}), Access.key(:project_slug)]) || "default"
  end

  defp run_review_turn(state, config, prompt, log_files) do
    review_config = reviewer_config(config)
    reviewer_opts = with_raw_log(%{}, log_files, :reviewer_stdout)

    case Agent.start_session(review_config, state.workspace, %{}) do
      {:ok, session} ->
        turn_result = Agent.run_turn(session, prompt, reviewer_opts)
        stop_result = Agent.stop_session(session)
        normalize_review_turn_result(turn_result, stop_result)

      {:error, reason} ->
        {:error, "failed to start reviewer session: #{reason}"}
    end
  end

  defp run_testing_turn(state, config, prompt, log_files) do
    testing_config = tester_config(config, state.runtime)
    tester_opts = with_raw_log(%{}, log_files, :tester_stdout)

    case Agent.start_session(testing_config, state.workspace, %{}) do
      {:ok, session} ->
        turn_result = Agent.run_turn(session, prompt, tester_opts)
        stop_result = Agent.stop_session(session)
        normalize_testing_turn_result(turn_result, stop_result)

      {:error, reason} ->
        {:error, "failed to start tester session: #{reason}"}
    end
  end

  defp with_raw_log(opts, %{agent_stdout: path}, :agent_stdout) when is_binary(path),
    do: Map.put(opts, :raw_log, path)

  defp with_raw_log(opts, %{reviewer_stdout: path}, :reviewer_stdout) when is_binary(path),
    do: Map.put(opts, :raw_log, path)

  defp with_raw_log(opts, %{tester_stdout: path}, :tester_stdout) when is_binary(path),
    do: Map.put(opts, :raw_log, path)

  defp with_raw_log(opts, _log_files, _key), do: opts

  defp normalize_review_turn_result({:ok, result}, :ok) when is_map(result) do
    case Map.get(result, :output) do
      output when is_binary(output) -> {:ok, output}
      _other -> {:error, "reviewer returned result without output"}
    end
  end

  defp normalize_review_turn_result({:error, reason}, :ok),
    do: {:error, "reviewer turn failed: #{reason}"}

  defp normalize_review_turn_result({:ok, _result}, {:error, stop_reason}),
    do: {:error, "failed to stop reviewer session: #{stop_reason}"}

  defp normalize_review_turn_result({:error, reason}, {:error, stop_reason}),
    do:
      {:error, "reviewer turn failed: #{reason}; failed to stop reviewer session: #{stop_reason}"}

  defp normalize_review_turn_result(other_result, other_stop_result) do
    {:error,
     "reviewer returned unexpected results: turn=#{inspect(other_result)} stop=#{inspect(other_stop_result)}"}
  end

  defp normalize_testing_turn_result({:ok, result}, :ok) when is_map(result) do
    case Map.get(result, :output) do
      output when is_binary(output) ->
        {:ok,
         %{
           output: output,
           command: Map.get(result, :command),
           args: Map.get(result, :args, []),
           duration_ms: Map.get(result, :duration_ms, 0)
         }}

      _other ->
        {:error, "tester returned result without output"}
    end
  end

  defp normalize_testing_turn_result({:error, reason}, :ok),
    do: {:error, "tester turn failed: #{reason}"}

  defp normalize_testing_turn_result({:ok, _result}, {:error, stop_reason}),
    do: {:error, "failed to stop tester session: #{stop_reason}"}

  defp normalize_testing_turn_result({:error, reason}, {:error, stop_reason}),
    do: {:error, "tester turn failed: #{reason}; failed to stop tester session: #{stop_reason}"}

  defp normalize_testing_turn_result(other_result, other_stop_result) do
    {:error,
     "tester returned unexpected results: turn=#{inspect(other_result)} stop=#{inspect(other_stop_result)}"}
  end

  defp read_review_json(nil), do: {:error, "review_json path not configured"}

  defp read_review_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"verdict" => "pass"}} ->
            {:ok, :pass}

          {:ok, %{"verdict" => "fail"} = review} ->
            feedback = format_review_feedback(review)
            {:ok, {:fail, feedback}}

          {:ok, _other} ->
            {:review_failed,
             "reviewer wrote invalid review.json: missing `verdict` (expected \"pass\" or \"fail\")"}

          {:error, reason} ->
            {:review_failed, "failed to parse review.json: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:review_failed, "reviewer did not write review.json"}

      {:error, reason} ->
        {:error, "failed to read review.json: #{inspect(reason)}"}
    end
  end

  defp read_testing_json(nil), do: {:error, "testing_json path not configured"}

  defp read_testing_json(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"verdict" => verdict} = testing} when verdict in ["pass", "fail"] ->
            summary = Map.get(testing, "summary", "") |> to_string() |> String.trim()
            checkpoints = normalize_testing_checkpoints(Map.get(testing, "checkpoints", []))
            artifacts = normalize_testing_artifacts(Map.get(testing, "artifacts", []))

            if verdict == "pass" do
              {:ok,
               %{
                 verdict: :pass,
                 summary: summary,
                 checkpoints: checkpoints,
                 artifacts: artifacts
               }}
            else
              {:ok,
               %{
                 verdict: :fail,
                 summary: summary,
                 checkpoints: checkpoints,
                 artifacts: artifacts,
                 feedback: format_testing_feedback(summary, checkpoints)
               }}
            end

          {:ok, _other} ->
            {:testing_failed,
             "tester wrote invalid testing.json: missing `verdict` (expected \"pass\" or \"fail\")"}

          {:error, reason} ->
            {:testing_failed, "failed to parse testing.json: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:testing_failed, "tester did not write testing.json"}

      {:error, reason} ->
        {:error, "failed to read testing.json: #{inspect(reason)}"}
    end
  end

  defp normalize_testing_checkpoints(value) when is_list(value) do
    value
    |> Enum.map(&normalize_testing_checkpoint/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_testing_checkpoints(_value), do: []

  defp normalize_testing_checkpoint(value) when is_map(value) do
    name =
      field(value, :name) ||
        field(value, :title) ||
        field(value, :id) ||
        "checkpoint"

    details =
      field(value, :details) ||
        field(value, :description) ||
        field(value, :note)

    status = normalize_testing_checkpoint_status(field(value, :status))

    if is_nil(status) do
      nil
    else
      %{
        name: to_string(name),
        status: status,
        details: optional_string(to_string(details || ""))
      }
    end
  end

  defp normalize_testing_checkpoint(_value), do: nil

  defp normalize_testing_checkpoint_status(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "pass" -> "pass"
      "passed" -> "pass"
      "ok" -> "pass"
      "fail" -> "fail"
      "failed" -> "fail"
      "warning" -> "warning"
      "warn" -> "warning"
      "skipped" -> "skipped"
      "" -> nil
      other -> other
    end
  end

  defp normalize_testing_checkpoint_status(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_testing_checkpoint_status()
  end

  defp normalize_testing_checkpoint_status(_value), do: nil

  defp normalize_testing_artifacts(value) when is_list(value) do
    value
    |> Enum.map(&normalize_testing_artifact/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_testing_artifacts(_value), do: []

  defp normalize_testing_artifact(value) when is_map(value) do
    path = optional_string(to_string(field(value, :path) || ""))

    if is_nil(path) do
      nil
    else
      %{
        kind: optional_string(to_string(field(value, :kind) || "")),
        path: path,
        description: optional_string(to_string(field(value, :description) || ""))
      }
    end
  end

  defp normalize_testing_artifact(_value), do: nil

  defp format_testing_feedback(summary, checkpoints) when is_list(checkpoints) do
    failing =
      checkpoints
      |> Enum.filter(fn checkpoint -> Map.get(checkpoint, :status) == "fail" end)
      |> Enum.map(fn checkpoint ->
        name = Map.get(checkpoint, :name, "checkpoint")
        details = optional_string(Map.get(checkpoint, :details))

        if details do
          "- #{name}: #{details}"
        else
          "- #{name}"
        end
      end)

    cond do
      failing != [] and summary != "" ->
        [summary, "", "Failed checkpoints:", Enum.join(failing, "\n")]
        |> Enum.join("\n")
        |> String.trim()

      failing != [] ->
        ["Failed checkpoints:", Enum.join(failing, "\n")]
        |> Enum.join("\n")
        |> String.trim()

      summary != "" ->
        summary

      true ->
        "tester reported a failing verdict"
    end
  end

  defp format_testing_feedback(summary, _checkpoints) when is_binary(summary) and summary != "",
    do: summary

  defp format_testing_feedback(_summary, _checkpoints), do: "tester reported a failing verdict"

  defp reset_review_json(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "failed to reset review.json: #{inspect(reason)}"}
    end
  end

  defp reset_review_json(_path), do: {:error, "review_json path not configured"}

  defp reset_testing_json(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "failed to reset testing.json: #{inspect(reason)}"}
    end
  end

  defp reset_testing_json(_path), do: {:error, "testing_json path not configured"}

  defp format_review_feedback(review) do
    summary = Map.get(review, "summary", "") |> to_string() |> String.trim()
    findings = Map.get(review, "findings", [])

    by_severity = Enum.group_by(findings, fn f -> Map.get(f, "severity", "minor") end)

    sections =
      ["critical", "major", "minor"]
      |> Enum.flat_map(fn sev ->
        case Map.get(by_severity, sev) do
          nil ->
            []

          items ->
            header = "## #{String.capitalize(sev)}"
            lines = Enum.map(items, fn f -> "- #{Map.get(f, "description", "")}" end)
            [header | lines]
        end
      end)

    prefix = if summary != "", do: "#{summary}\n\n", else: ""
    "#{prefix}#{Enum.join(sections, "\n")}" |> String.trim()
  end

  defp build_review_prompt(state, config, cycle, rjp) do
    template = review_prompt_template(config)

    variables =
      prompt_variables(state.issue, state.attempt, include_failure_context: false)
      |> Map.put("review_json_path", rjp)
      |> Map.put("cycle", cycle)

    case PromptBuilder.render(template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render review prompt: #{reason}"}
    end
  end

  defp build_testing_prompt(state, config, cycle, tjp) do
    template = testing_prompt_template(config)

    variables =
      prompt_variables(state.issue, state.attempt,
        include_testing_notes: true,
        include_failure_context: false
      )
      |> Map.put("testing_json_path", tjp)
      |> Map.put("cycle", cycle)
      |> Map.put("runtime_base_url", testing_runtime_base_url(state.runtime))
      |> Map.put("runtime_urls_json", testing_runtime_urls_json(state.runtime))
      |> Map.put("runtime_url_hints", testing_runtime_url_hints(state.runtime))

    case PromptBuilder.render(template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render testing prompt: #{reason}"}
    end
  end

  defp testing_runtime_base_url(runtime) do
    case default_runtime_port(runtime) do
      nil -> "http://127.0.0.1:3000"
      port -> "http://127.0.0.1:#{port}"
    end
  end

  defp testing_runtime_urls_json(runtime) do
    runtime
    |> testing_runtime_urls()
    |> Jason.encode!()
  end

  defp testing_runtime_url_hints(runtime) do
    urls = testing_runtime_urls(runtime)

    if map_size(urls) == 0 do
      "- (no explicit runtime ports found; use the base URL)"
    else
      urls
      |> Enum.sort_by(fn {name, _url} -> name end)
      |> Enum.map_join("\n", fn {name, url} -> "- #{name}: #{url}" end)
    end
  end

  defp testing_runtime_urls(runtime) when is_map(runtime) do
    resolved =
      runtime
      |> Map.get(:resolved_ports, %{})
      |> map_or_empty()

    env =
      runtime
      |> Map.get(:env, %{})
      |> map_or_empty()

    ports =
      resolved
      |> Enum.reduce(%{}, fn {name, value}, acc ->
        case parse_runtime_port(value) do
          nil -> acc
          port -> Map.put(acc, to_string(name), port)
        end
      end)
      |> then(fn acc ->
        if map_size(acc) == 0 do
          acc
          |> maybe_put_port("APP_PORT", Map.get(env, "APP_PORT"))
          |> maybe_put_port("PORT", Map.get(env, "PORT"))
        else
          acc
        end
      end)

    ports
    |> Enum.reduce(%{}, fn {name, port}, acc ->
      Map.put(acc, name, "http://127.0.0.1:#{port}")
    end)
  end

  defp testing_runtime_urls(_runtime), do: %{}

  defp default_runtime_port(runtime) do
    runtime
    |> Map.get(:resolved_ports, %{})
    |> map_or_empty()
    |> then(fn ports ->
      parse_runtime_port(Map.get(ports, "APP_PORT")) ||
        parse_runtime_port(Map.get(ports, "PORT")) ||
        runtime
        |> Map.get(:env, %{})
        |> map_or_empty()
        |> then(fn env ->
          parse_runtime_port(Map.get(env, "APP_PORT")) || parse_runtime_port(Map.get(env, "PORT"))
        end)
    end)
  end

  defp testing_runtime_env(runtime) do
    urls = testing_runtime_urls(runtime)
    base_url = testing_runtime_base_url(runtime)

    url_env =
      urls
      |> Enum.reduce(%{}, fn {name, url}, acc ->
        env_key = "KOLLYWOOD_URL_" <> normalize_runtime_env_suffix(name)
        Map.put(acc, env_key, url)
      end)

    %{
      "KOLLYWOOD_RUNTIME_BASE_URL" => base_url,
      "KOLLYWOOD_BASE_URL" => base_url,
      "KOLLYWOOD_RUNTIME_URLS_JSON" => Jason.encode!(urls)
    }
    |> Map.merge(url_env)
  end

  defp normalize_runtime_env_suffix(name) do
    normalized =
      name
      |> to_string()
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9_]/, "_")

    if String.match?(normalized, ~r/^[0-9]/), do: "P_#{normalized}", else: normalized
  end

  defp maybe_put_port(acc, key, value) when is_map(acc) do
    case parse_runtime_port(value) do
      nil -> acc
      port -> Map.put_new(acc, key, port)
    end
  end

  defp parse_runtime_port(value) when is_integer(value) and value > 0, do: value

  defp parse_runtime_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port > 0 -> port
      _other -> nil
    end
  end

  defp parse_runtime_port(_value), do: nil

  defp workspace_review_json_path(%{path: path}) when is_binary(path) do
    dir = Path.join(path, ".kollywood")
    File.mkdir_p!(dir)
    Path.join(dir, "review.json")
  end

  defp workspace_review_json_path(_),
    do:
      Path.join(
        System.tmp_dir!(),
        "kollywood_review_#{System.unique_integer([:positive, :monotonic])}.json"
      )

  defp workspace_testing_json_path(%{path: path}) when is_binary(path) do
    dir = Path.join(path, ".kollywood")
    File.mkdir_p!(dir)
    Path.join(dir, "testing.json")
  end

  defp workspace_testing_json_path(_),
    do:
      Path.join(
        System.tmp_dir!(),
        "kollywood_testing_#{System.unique_integer([:positive, :monotonic])}.json"
      )

  defp persist_review_json(src, %{review_json: dest}) when is_binary(dest) do
    File.copy(src, dest)
    :ok
  end

  defp persist_review_json(_src, _log_files), do: :ok

  defp persist_testing_json(src, %{testing_json: dest}) when is_binary(dest) do
    _ = File.mkdir_p(Path.dirname(dest))
    File.copy(src, dest)
    :ok
  end

  defp persist_testing_json(_src, _log_files), do: :ok

  defp persist_review_cycle_json(src, %{review_cycles_dir: dir}, cycle)
       when is_binary(src) and is_binary(dir) and is_integer(cycle) and cycle > 0 do
    if File.exists?(src) do
      _ = File.mkdir_p(dir)
      File.copy(src, Path.join(dir, cycle_report_filename(cycle)))
    end

    :ok
  end

  defp persist_review_cycle_json(_src, _log_files, _cycle), do: :ok

  defp persist_testing_cycle_json(src, %{testing_cycles_dir: dir}, cycle)
       when is_binary(src) and is_binary(dir) and is_integer(cycle) and cycle > 0 do
    if File.exists?(src) do
      _ = File.mkdir_p(dir)
      File.copy(src, Path.join(dir, cycle_report_filename(cycle)))
    end

    :ok
  end

  defp persist_testing_cycle_json(_src, _log_files, _cycle), do: :ok

  defp persist_testing_cycle_report(%{} = testing, %{testing_cycles_dir: dir}, cycle)
       when is_binary(dir) and is_integer(cycle) and cycle > 0 do
    path = Path.join(dir, cycle_report_filename(cycle))
    _ = write_testing_report(testing, path)
    :ok
  end

  defp persist_testing_cycle_report(_testing, _log_files, _cycle), do: :ok

  defp cycle_report_filename(cycle) when is_integer(cycle) and cycle > 0 do
    padded = cycle |> Integer.to_string() |> String.pad_leading(3, "0")
    "cycle-" <> padded <> ".json"
  end

  defp persist_testing_report(%{} = testing, workspace, log_files) do
    workspace_path = workspace_path(workspace)
    report_path = testing_report_path(log_files)
    artifacts_dir = testing_artifacts_dir(log_files)

    if is_binary(report_path) or is_binary(artifacts_dir) do
      artifacts =
        if is_binary(artifacts_dir) do
          testing
          |> Map.get(:artifacts, [])
          |> persist_testing_artifacts(workspace_path, artifacts_dir)
        else
          Map.get(testing, :artifacts, [])
        end

      report = Map.put(testing, :artifacts, artifacts)
      _ = write_testing_report(report, report_path)
      report
    else
      testing
    end
  end

  defp persist_testing_report(testing, _workspace, _log_files), do: testing

  defp persist_testing_artifacts(artifacts, workspace_path, artifacts_dir)
       when is_list(artifacts) do
    artifacts
    |> Enum.with_index(1)
    |> Enum.map(fn {artifact, index} ->
      persist_testing_artifact(artifact, index, workspace_path, artifacts_dir)
    end)
  end

  defp persist_testing_artifacts(_artifacts, _workspace_path, _artifacts_dir), do: []

  defp persist_testing_artifact(%{} = artifact, index, workspace_path, artifacts_dir) do
    path = optional_string(Map.get(artifact, :path))

    cond do
      is_nil(path) ->
        artifact

      testing_artifact_remote_path?(path) ->
        artifact

      not is_binary(workspace_path) ->
        Map.put(artifact, :storage_error, "workspace path unavailable")

      not is_binary(artifacts_dir) ->
        Map.put(artifact, :storage_error, "testing artifacts directory unavailable")

      true ->
        source_path = resolve_testing_artifact_source(path, workspace_path)

        cond do
          not is_binary(source_path) ->
            Map.put(artifact, :storage_error, "invalid artifact path: #{path}")

          not File.exists?(source_path) ->
            artifact
            |> Map.put(:source_path, source_path)
            |> Map.put(:storage_error, "artifact file not found")

          not File.regular?(source_path) ->
            artifact
            |> Map.put(:source_path, source_path)
            |> Map.put(:storage_error, "artifact path is not a file")

          true ->
            _ = File.mkdir_p(artifacts_dir)
            dest_path = testing_artifact_dest_path(artifact, index, source_path, artifacts_dir)

            case File.copy(source_path, dest_path) do
              {:ok, _bytes} ->
                artifact
                |> Map.put(:source_path, source_path)
                |> Map.put(:stored_path, dest_path)

              {:error, reason} ->
                artifact
                |> Map.put(:source_path, source_path)
                |> Map.put(:storage_error, "failed to copy artifact: #{inspect(reason)}")
            end
        end
    end
  end

  defp persist_testing_artifact(artifact, _index, _workspace_path, _artifacts_dir), do: artifact

  defp testing_artifact_remote_path?(path) when is_binary(path) do
    String.match?(path, ~r/^[a-z][a-z0-9+.-]*:\/\//i)
  end

  defp testing_artifact_remote_path?(_path), do: false

  defp resolve_testing_artifact_source(path, workspace_path)
       when is_binary(path) and is_binary(workspace_path) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.expand(path, workspace_path)
    end
  end

  defp resolve_testing_artifact_source(_path, _workspace_path), do: nil

  defp testing_artifact_dest_path(artifact, index, source_path, artifacts_dir)
       when is_map(artifact) and is_integer(index) and is_binary(source_path) and
              is_binary(artifacts_dir) do
    kind =
      artifact
      |> Map.get(:kind)
      |> optional_string()
      |> Kernel.||("artifact")
      |> sanitize_testing_artifact_segment()

    basename =
      source_path
      |> Path.basename()
      |> sanitize_testing_artifact_segment()
      |> case do
        "" -> "artifact"
        value -> value
      end

    prefix = index |> Integer.to_string() |> String.pad_leading(3, "0")
    Path.join(artifacts_dir, "#{prefix}_#{kind}_#{basename}")
  end

  defp sanitize_testing_artifact_segment(value) when is_binary(value) do
    value
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.trim("_")
  end

  defp sanitize_testing_artifact_segment(value),
    do: value |> to_string() |> sanitize_testing_artifact_segment()

  defp write_testing_report(%{} = testing, path) when is_binary(path) do
    _ = File.mkdir_p(Path.dirname(path))
    payload = testing_report_payload(testing)
    encoded = Jason.encode_to_iodata!(payload, pretty: true)
    File.write(path, [encoded, "\n"])
  end

  defp write_testing_report(_testing, _path), do: :ok

  defp testing_report_path(%{testing_report: path}) when is_binary(path), do: path

  defp testing_report_path(%{testing_json: testing_json}) when is_binary(testing_json) do
    Path.join(Path.dirname(testing_json), "testing_report.json")
  end

  defp testing_report_path(_log_files), do: nil

  defp testing_artifacts_dir(%{testing_artifacts_dir: path}) when is_binary(path), do: path

  defp testing_artifacts_dir(%{testing_json: testing_json}) when is_binary(testing_json) do
    Path.join(Path.dirname(testing_json), "testing_artifacts")
  end

  defp testing_artifacts_dir(_log_files), do: nil

  defp testing_report_payload(%{} = testing) do
    %{
      "verdict" => testing_verdict_string(Map.get(testing, :verdict)),
      "summary" => Map.get(testing, :summary),
      "checkpoints" => testing_checkpoint_payloads(Map.get(testing, :checkpoints, [])),
      "artifacts" => testing_artifact_payloads(Map.get(testing, :artifacts, []))
    }
    |> compact_report_map()
  end

  defp testing_report_payload(_testing), do: %{}

  defp testing_verdict_string(:pass), do: "pass"
  defp testing_verdict_string(:fail), do: "fail"
  defp testing_verdict_string(value) when is_binary(value), do: value
  defp testing_verdict_string(value) when is_atom(value), do: Atom.to_string(value)
  defp testing_verdict_string(_value), do: nil

  defp testing_checkpoint_payloads(checkpoints) when is_list(checkpoints) do
    Enum.map(checkpoints, fn checkpoint ->
      %{
        "name" => Map.get(checkpoint, :name),
        "status" => Map.get(checkpoint, :status),
        "details" => Map.get(checkpoint, :details)
      }
      |> compact_report_map()
    end)
  end

  defp testing_checkpoint_payloads(_checkpoints), do: []

  defp testing_artifact_payloads(artifacts) when is_list(artifacts) do
    Enum.map(artifacts, fn artifact ->
      %{
        "kind" => Map.get(artifact, :kind),
        "path" => Map.get(artifact, :path),
        "description" => Map.get(artifact, :description),
        "source_path" => Map.get(artifact, :source_path),
        "stored_path" => Map.get(artifact, :stored_path),
        "storage_error" => Map.get(artifact, :storage_error)
      }
      |> compact_report_map()
    end)
  end

  defp testing_artifact_payloads(_artifacts), do: []

  defp compact_report_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} ->
      v in [nil, ""] or (is_list(v) and v == []) or (is_map(v) and map_size(v) == 0)
    end)
    |> Map.new()
  end

  defp build_review_remediation_prompt(state, review_feedback, cycle, prompt_template) do
    base_variables = prompt_variables(state.issue, state.attempt, include_failure_context: true)

    base_prompt =
      case PromptBuilder.render(prompt_template, base_variables) do
        {:ok, prompt} -> prompt
        {:error, _reason} -> ""
      end

    remediation_template =
      """
      Continue working on issue {{ issue.identifier }}: {{ issue.title }}.

      Previous assignment:
      {{ base_prompt }}

      Reviewer feedback from cycle {{ cycle }}:
      {{ review_feedback }}

      Fix the issues raised by the reviewer, update code/tests as needed, and provide a concise summary.
      """

    variables =
      base_variables
      |> Map.put("review_feedback", review_feedback)
      |> Map.put("cycle", cycle)
      |> Map.put("base_prompt", base_prompt)

    case PromptBuilder.render(remediation_template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render remediation prompt: #{reason}"}
    end
  end

  defp build_testing_remediation_prompt(state, testing_feedback, cycle, prompt_template) do
    base_variables = prompt_variables(state.issue, state.attempt, include_failure_context: true)

    base_prompt =
      case PromptBuilder.render(prompt_template, base_variables) do
        {:ok, prompt} -> prompt
        {:error, _reason} -> ""
      end

    remediation_template =
      """
      Continue working on issue {{ issue.identifier }}: {{ issue.title }}.

      Previous assignment:
      {{ base_prompt }}

      Tester feedback from cycle {{ cycle }}:
      {{ testing_feedback }}

      Fix the issues raised by testing so the feature behaves correctly end-to-end.
      """

    variables =
      base_variables
      |> Map.put("testing_feedback", testing_feedback)
      |> Map.put("cycle", cycle)
      |> Map.put("base_prompt", base_prompt)

    case PromptBuilder.render(remediation_template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render testing remediation prompt: #{reason}"}
    end
  end

  defp reviewer_config(config) do
    review_agent =
      config
      |> review_config()
      |> Map.get(:agent, %{})

    base_agent = Map.get(config, :agent, %{})

    merged_agent =
      if Map.get(review_agent, :explicit, false) do
        # review.agent explicitly configured — start from base agent, apply overrides
        base_agent
        |> Map.put(:kind, Map.get(review_agent, :kind, Map.get(base_agent, :kind)))
        |> Map.put(:max_turns, 1)
        |> then(fn a ->
          case Map.get(review_agent, :command) do
            nil -> a
            cmd -> Map.put(a, :command, cmd)
          end
        end)
        |> then(fn a ->
          case Map.get(review_agent, :args) do
            [] -> a
            args -> Map.put(a, :args, args)
          end
        end)
        |> Map.put(
          :env,
          Map.merge(Map.get(base_agent, :env, %{}), Map.get(review_agent, :env, %{}))
        )
        |> Map.put(
          :timeout_ms,
          positive_integer(
            Map.get(review_agent, :timeout_ms, Map.get(base_agent, :timeout_ms, 7_200_000)),
            7_200_000
          )
        )
      else
        # No review.agent configured — use main agent config as-is, just cap max_turns to 1
        Map.put(base_agent, :max_turns, 1)
      end

    %Config{config | agent: merged_agent}
  end

  defp tester_config(config, runtime) do
    testing_agent =
      config
      |> testing_config()
      |> Map.get(:agent, %{})

    base_agent = Map.get(config, :agent, %{})
    runtime_env = testing_runtime_env(runtime)
    default_timeout = testing_timeout_ms(config)

    merged_agent =
      if Map.get(testing_agent, :explicit, false) do
        # testing.agent explicitly configured — start from base agent, apply overrides
        base_agent
        |> Map.put(:kind, Map.get(testing_agent, :kind, Map.get(base_agent, :kind)))
        |> Map.put(:max_turns, 1)
        |> then(fn a ->
          case Map.get(testing_agent, :command) do
            nil -> a
            cmd -> Map.put(a, :command, cmd)
          end
        end)
        |> then(fn a ->
          case Map.get(testing_agent, :args) do
            [] -> a
            args -> Map.put(a, :args, args)
          end
        end)
        |> Map.put(
          :env,
          base_agent
          |> Map.get(:env, %{})
          |> map_or_empty()
          |> Map.merge(Map.get(testing_agent, :env, %{}) |> map_or_empty())
          |> Map.merge(runtime_env)
        )
        |> Map.put(
          :timeout_ms,
          positive_integer(
            Map.get(
              testing_agent,
              :timeout_ms,
              Map.get(base_agent, :timeout_ms, default_timeout)
            ),
            default_timeout
          )
        )
      else
        # No testing.agent configured — use main agent config with runtime env and cap max_turns.
        base_agent
        |> Map.put(:max_turns, 1)
        |> Map.put(
          :env,
          base_agent
          |> Map.get(:env, %{})
          |> map_or_empty()
          |> Map.merge(runtime_env)
        )
        |> Map.put(
          :timeout_ms,
          positive_integer(Map.get(base_agent, :timeout_ms), default_timeout)
        )
      end

    %Config{config | agent: merged_agent}
  end

  defp with_agent_browser_defaults(%Config{} = config, workspace) do
    agent = Map.get(config, :agent, %{})

    env =
      agent
      |> Map.get(:env, %{})
      |> map_or_empty()

    browser_env = agent_browser_env(workspace, env)

    if map_size(browser_env) == 0 do
      config
    else
      %Config{config | agent: Map.put(agent, :env, Map.merge(env, browser_env))}
    end
  end

  defp agent_browser_env(%{path: workspace_path}, existing_env)
       when is_binary(workspace_path) and is_map(existing_env) do
    artifacts_dir = Path.join(workspace_path, ".kollywood/artifacts/testing")
    downloads_dir = Path.join(artifacts_dir, "downloads")

    _ = File.mkdir_p(artifacts_dir)
    _ = File.mkdir_p(downloads_dir)

    ffmpeg_dir = bundled_ffmpeg_dir(workspace_path)

    %{
      "AGENT_BROWSER_ARGS" => "--no-sandbox",
      "AGENT_BROWSER_SCREENSHOT_DIR" => artifacts_dir,
      "AGENT_BROWSER_DOWNLOAD_PATH" => downloads_dir
    }
    |> maybe_put_agent_path(existing_env, ffmpeg_dir)
  end

  defp agent_browser_env(_workspace, _existing_env), do: %{}

  defp bundled_ffmpeg_dir(workspace_path) do
    Path.join([
      workspace_path,
      ".kollywood",
      "artifacts",
      "testing",
      "ffmpeg-static",
      "*",
      "ffmpeg"
    ])
    |> Path.wildcard()
    |> Enum.find(&ffmpeg_binary?/1)
    |> case do
      nil -> nil
      path -> Path.dirname(path)
    end
  end

  defp ffmpeg_binary?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp maybe_put_agent_path(env, _existing_env, nil), do: env

  defp maybe_put_agent_path(env, existing_env, ffmpeg_dir) do
    base_path = env_value(existing_env, "PATH") || System.get_env("PATH") || ""
    entries = String.split(base_path, ":", trim: true)

    path_value =
      if ffmpeg_dir in entries do
        Enum.join(entries, ":")
      else
        Enum.join([ffmpeg_dir | entries], ":")
      end

    if path_value == "" do
      env
    else
      Map.put(env, "PATH", path_value)
    end
  end

  defp env_value(env, key) when is_map(env) and is_binary(key) do
    case Map.fetch(env, key) do
      {:ok, value} ->
        to_string(value)

      :error ->
        Enum.find_value(env, fn
          {k, v} when is_atom(k) ->
            if Atom.to_string(k) == key, do: to_string(v), else: nil

          _ ->
            nil
        end)
    end
  end

  defp required_check_commands(config) do
    config
    |> checks_config()
    |> Map.get(:required, [])
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  defp checks_timeout_ms(config) do
    config
    |> checks_config()
    |> Map.get(:timeout_ms, 7_200_000)
    |> positive_integer(7_200_000)
  end

  defp checks_fail_fast?(config) do
    config
    |> checks_config()
    |> Map.get(:fail_fast, true)
    |> truthy?()
  end

  defp review_enabled?(config) do
    config
    |> review_config()
    |> Map.get(:enabled, false)
    |> truthy?()
  end

  defp testing_enabled?(config) do
    config
    |> testing_config()
    |> Map.get(:enabled, false)
    |> truthy?()
  end

  defp quality_max_cycles(config) do
    case quality_config(config) |> Map.get(:max_cycles) do
      value when not is_nil(value) ->
        positive_integer(value, 1)

      _other ->
        config
        |> review_config()
        |> Map.get(:max_cycles, 1)
        |> positive_integer(1)
    end
  end

  defp checks_max_cycles(config) do
    default_limit = quality_max_cycles(config)

    config
    |> checks_config()
    |> Map.get(:max_cycles, default_limit)
    |> positive_integer(default_limit)
  end

  defp review_max_cycles(config) do
    default_limit = quality_max_cycles(config)

    config
    |> review_config()
    |> Map.get(:max_cycles, default_limit)
    |> positive_integer(default_limit)
  end

  defp testing_max_cycles(config) do
    default_limit = quality_max_cycles(config)

    config
    |> testing_config()
    |> Map.get(:max_cycles, default_limit)
    |> positive_integer(default_limit)
  end

  defp testing_timeout_ms(config) do
    config
    |> testing_config()
    |> Map.get(:timeout_ms, 7_200_000)
    |> positive_integer(7_200_000)
  end

  defp review_agent_kind(config) do
    config
    |> review_config()
    |> get_in([Access.key(:agent, %{}), Access.key(:kind)])
    |> case do
      value when value in [:amp, :claude, :cursor, :opencode, :pi] -> value
      _other -> Map.get(config.agent, :kind)
    end
  end

  defp testing_agent_kind(config) do
    config
    |> testing_config()
    |> get_in([Access.key(:agent, %{}), Access.key(:kind)])
    |> case do
      value when value in [:amp, :claude, :cursor, :opencode, :pi] -> value
      _other -> Map.get(config.agent, :kind)
    end
  end

  @default_review_prompt_template """
  You are reviewing work for issue {{ issue.identifier }}: {{ issue.title }}.

  Issue description:
  {{ issue.description }}

  Run `git diff` and `git log` to see what was changed. You may run read-only commands
  (tests, linters, type checkers) for validation. Do not modify files, do not commit, and do not push.

  Write your review to `{{ review_json_path }}` as a JSON file with this exact structure:

  ```json
  {
    "verdict": "pass",
    "summary": "One or two sentence summary of overall quality.",
    "findings": [
      {"severity": "critical", "description": "Description and where to find it"},
      {"severity": "major", "description": "..."},
      {"severity": "minor", "description": "..."}
    ]
  }
  ```

  Rules:
  - `verdict` must be exactly `"pass"` or `"fail"`
  - Use `"fail"` if there are any critical findings; use `"pass"` otherwise
  - `"critical"`: bugs, broken tests, security issues, missing required functionality
  - `"major"`: significant quality issues (poor design, missing error handling, test coverage gaps)
  - `"minor"`: style issues, naming, nice-to-haves
  - Omit findings for severities with no issues
  - Overwrite `{{ review_json_path }}` with exactly one JSON object; do not append multiple JSON objects
  - Write the file, then stop — do not print the review to stdout
  """

  @doc "Returns the default review prompt template used when none is configured in WORKFLOW.md."
  def default_review_prompt_template, do: @default_review_prompt_template

  @default_testing_prompt_template """
  You are testing work for issue {{ issue.identifier }}: {{ issue.title }}.

  Issue description:
  {{ issue.description }}

  Pipeline context (important):
  - Implementation is already complete for this cycle.
  - Required checks and review have already been performed in earlier pipeline phases.
  - Your job in this phase is product behavior validation and evidence capture only.

  Testing notes (for testing agent only):
  {{ testing_notes }}

  Runtime URLs (injected by runtime):
  - Base URL: {{ runtime_base_url }}
  - URL map (JSON): {{ runtime_urls_json }}
  - URL hints:
  {{ runtime_url_hints }}

  Keep this run fast and focused:
  - test the intended story feature first, from a user/outcome perspective
  - then cover one nearby regression and one boundary/invalid-input scenario
  - use targeted checks only; do not re-run broad validation already handled earlier
  - avoid repository/toolchain investigations unless they are strictly required to explain an observed feature failure
  - finish evidence collection with minimal retries and bounded waits

  Validate implemented behavior end-to-end (UI/API/CLI as relevant), including:
  - acceptance flow for this issue
  - nearby regression flow affected by the implementation
  - one boundary or invalid-input scenario

  For browser validation, use `agent-browser` when available. Capture evidence:
  - at least one screenshot
  - at least one short, focused video (`.webm` preferred, aim for 10-30 seconds max)
  - for UI-focused issues, evidence must visibly show the issue-specific control/text/state (generic top-of-page captures are insufficient)
  - navigate to the issue-relevant screen and ensure the target element is in view before capture; scroll as needed
  - video must demonstrate ONLY the key behavior being tested: navigate directly to the relevant page, perform the specific interaction, and stop recording once the result is visible — do not record setup, unrelated navigation, or idle time
  - if multiple behaviors need demonstration, prefer separate short clips over one long recording
  - include replay/trace/HAR artifacts when they help debugging
  - do not start app services manually; runtime has already started managed processes
  - do not install or bootstrap tooling in this phase (`npm`, `pip`, `cargo`, package managers)
  - if `agent-browser` is unavailable, do not attempt installation; continue with what is available and write a failing report that clearly names the browser tooling blocker
  - keep browser artifacts inside the workspace (`.kollywood/artifacts/testing`); do not use `~/.agent-browser/...` paths in reports
  - for screenshots, prefer `agent-browser screenshot --screenshot-dir .kollywood/artifacts/testing`; avoid a leading-dot path as the first positional argument because it can be parsed as a CSS selector
  - use only injected runtime URLs (`runtime_base_url` / `runtime_urls_json`); do not scan arbitrary localhost ports
  - avoid interactive commands/flags (for example `snapshot -i`) in CI/agent runs
  - avoid waiting for `networkidle` on apps with long-lived traffic; prefer bounded waits
  - if a browser command appears stuck, retry once with a short timeout and continue with direct captures

  Write your testing report to `{{ testing_json_path }}` as one JSON object:
  {
    "verdict": "pass",
    "summary": "One or two sentence outcome.",
    "checkpoints": [
      {"name":"acceptance flow","status":"pass","details":"what was validated"},
      {"name":"boundary case","status":"fail","details":"what failed and repro notes"}
    ],
    "artifacts": [
      {"kind":"screenshot","path":".kollywood/artifacts/testing/smoke.png","description":"optional"},
      {"kind":"video","path":".kollywood/artifacts/testing/demo.webm","description":"optional"},
      {"kind":"replay","path":".kollywood/artifacts/testing/replay.html","description":"optional"},
      {"kind":"trace","path":".kollywood/artifacts/testing/trace.zip","description":"optional"}
    ]
  }

  Rules:
  - `verdict` must be exactly `"pass"` or `"fail"`.
  - Include at least one checkpoint.
  - Use `"fail"` if acceptance behavior fails or required coverage is missing.
  - Always write `{{ testing_json_path }}` even when blocked (for example runtime/access/tooling issues); in that case use `"fail"` and explain the blocker in checkpoint `details`.
  - If screenshot/video artifacts do not visibly demonstrate the claimed acceptance behavior, use `"fail"` and explain what is missing.
  - Artifact `description` should say what behavior is proven and which checkpoint it supports.
  - Overwrite `{{ testing_json_path }}` exactly once (do not append multiple JSON objects).
  - If behavior fails, include clear repro details in checkpoint `details`.
  """

  @doc "Returns the default testing prompt template used when none is configured in WORKFLOW.md."
  def default_testing_prompt_template, do: @default_testing_prompt_template

  defp review_prompt_template(config) do
    case config |> review_config() |> Map.get(:prompt_template) do
      value when is_binary(value) and value != "" -> value
      _other -> @default_review_prompt_template
    end
  end

  defp testing_prompt_template(config) do
    case config |> testing_config() |> Map.get(:prompt_template) do
      value when is_binary(value) and value != "" -> value
      _other -> @default_testing_prompt_template
    end
  end

  defp quality_config(config), do: Map.get(config, :quality) || %{}

  defp checks_config(config) do
    case Map.get(config, :checks) do
      checks when is_map(checks) ->
        checks

      _other ->
        case quality_config(config) |> Map.get(:checks) do
          checks when is_map(checks) -> checks
          _other -> %{}
        end
    end
  end

  defp review_config(config) do
    case Map.get(config, :review) do
      review when is_map(review) ->
        review

      _other ->
        case quality_config(config) |> Map.get(:review) do
          review when is_map(review) -> review
          _other -> %{}
        end
    end
  end

  defp testing_config(config) do
    case Map.get(config, :testing) do
      testing when is_map(testing) ->
        testing

      _other ->
        case quality_config(config) |> Map.get(:testing) do
          testing when is_map(testing) -> testing
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
      _ -> false
    end
  end

  defp truthy?(_value), do: false

  defp output_preview(output) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 600)
  end

  defp output_preview(_output), do: ""

  defp preview_suffix(""), do: ""
  defp preview_suffix(preview), do: " | output: #{inspect(preview)}"

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp result_from_state(state, status, error) do
    %Result{
      issue_id: state.issue_id,
      identifier: state.identifier,
      workspace_path: workspace_path(state.workspace),
      turn_count: state.turn_count,
      status: status,
      started_at: state.started_at,
      ended_at: DateTime.utc_now(),
      last_output: state.last_output,
      events: Enum.reverse(state.events_rev),
      error: error
    }
  end

  defp workspace_path(%{path: path}), do: path
  defp workspace_path(_workspace), do: nil

  defp emit(state, type, attrs) do
    event =
      %{
        type: type,
        timestamp: DateTime.utc_now(),
        issue_id: state.issue_id,
        identifier: state.identifier
      }
      |> Map.merge(attrs)

    dispatch_event(state.on_event, event)
    %{state | events_rev: [event | state.events_rev]}
  end

  defp dispatch_event(on_event, event) do
    on_event.(event)
  rescue
    error ->
      Logger.warning("AgentRunner on_event callback failed: #{Exception.message(error)}")
  end

  defp issue_meta(issue) do
    case field(issue, :identifier) do
      identifier when is_binary(identifier) and identifier != "" ->
        {:ok, %{id: optional_string(field(issue, :id)), identifier: identifier}}

      _ ->
        {:error, "Issue identifier is required"}
    end
  end

  defp resolve_workflow(issue, opts) do
    workflow_store = Keyword.get(opts, :workflow_store, WorkflowStore)
    config = Keyword.get(opts, :config) || WorkflowStore.get_config(workflow_store)

    prompt_template =
      Keyword.get(opts, :prompt_template) || WorkflowStore.get_prompt_template(workflow_store)

    story_overrides_resolved? = Keyword.get(opts, :story_overrides_resolved, false)
    provided_snapshot = Keyword.get(opts, :run_settings_snapshot)

    cond do
      not match?(%Config{}, config) ->
        {:error, "Workflow config is unavailable"}

      not (is_binary(prompt_template) and prompt_template != "") ->
        {:error, "Workflow prompt template is unavailable"}

      story_overrides_resolved? ->
        run_settings_snapshot =
          if is_map(provided_snapshot),
            do: provided_snapshot,
            else: StoryExecutionOverrides.snapshot(config)

        {:ok, config, prompt_template, run_settings_snapshot}

      true ->
        case StoryExecutionOverrides.resolve(config, issue) do
          {:ok, resolved} ->
            {:ok, resolved.config, prompt_template, resolved.settings_snapshot}

          {:error, reason} ->
            {:error, "invalid story execution settings: #{reason}"}
        end
    end
  end

  defp parse_mode(mode) when mode in [:single_turn, :max_turns], do: {:ok, mode}
  defp parse_mode(_mode), do: {:error, "mode must be :single_turn or :max_turns"}

  defp parse_retry_step(step) when step in [:checks, :review, :testing, :publish], do: {:ok, step}

  defp parse_retry_step(_step),
    do: {:error, "retry step must be one of: :checks, :review, :testing, :publish"}

  defp parse_attempt(nil), do: {:ok, nil}
  defp parse_attempt(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_attempt(_value), do: {:error, "attempt must be nil or a non-negative integer"}

  defp parse_turn_limit(config, nil) do
    parse_positive_integer(Map.get(config.agent, :max_turns), "config.agent.max_turns")
  end

  defp parse_turn_limit(_config, value) do
    parse_positive_integer(value, "turn_limit")
  end

  defp parse_positive_integer(value, _label) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_positive_integer(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, "#{label} must be a positive integer"}
    end
  end

  defp parse_positive_integer(_value, label), do: {:error, "#{label} must be a positive integer"}

  defp parse_continuation_opts(nil), do: {:ok, nil}

  defp parse_continuation_opts(value) do
    case normalize_opts(value, "continuation") do
      {:ok, continuation} when map_size(continuation) == 0 ->
        {:ok, nil}

      {:ok, continuation} ->
        {:ok, normalize_continuation_payload(continuation)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_continuation_payload(continuation) when is_map(continuation) do
    normalized = %{
      mode: continuation_mode(field(continuation, :mode)),
      source: field(continuation, :source),
      originating_attempt: field(continuation, :originating_attempt),
      continuation_attempt: field(continuation, :continuation_attempt),
      last_successful_turn: field(continuation, :last_successful_turn),
      failure_reason: field(continuation, :failure_reason),
      originating_session_id: field(continuation, :originating_session_id)
    }

    Enum.reduce(normalized, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp normalize_continuation_payload(_continuation), do: %{}

  defp normalize_opts(value, _label) when is_map(value), do: {:ok, value}

  defp normalize_opts(value, label) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      {:error, "#{label} must be a map or keyword list"}
    end
  end

  defp normalize_opts(_value, label), do: {:error, "#{label} must be a map or keyword list"}

  defp parse_on_event(on_event) when is_function(on_event, 1), do: {:ok, on_event}
  defp parse_on_event(_on_event), do: {:error, "on_event must be a function with arity 1"}

  defp combine_errors(nil, stop_reason), do: stop_reason
  defp combine_errors(run_reason, _stop_reason), do: run_reason

  defp merge_error_messages(primary, secondary) do
    cond do
      blank_error?(primary) -> secondary
      blank_error?(secondary) -> primary
      primary == secondary -> primary
      true -> "#{primary}; #{secondary}"
    end
  end

  defp blank_error?(value), do: not (is_binary(value) and String.trim(value) != "")

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp prompt_variables(issue, attempt, opts) do
    include_testing_notes? = Keyword.get(opts, :include_testing_notes, false)
    include_failure_context? = Keyword.get(opts, :include_failure_context, false)

    prompt_issue =
      issue
      |> strip_testing_notes()
      |> maybe_attach_failure_context(include_failure_context?)

    variables =
      prompt_issue
      |> PromptBuilder.build_variables(attempt)

    if include_testing_notes? do
      notes = testing_notes(issue)
      issue_variables = variables |> Map.get("issue", %{}) |> Map.put("testing_notes", notes)

      variables
      |> Map.put("issue", issue_variables)
      |> Map.put("testing_notes", notes)
    else
      variables
    end
  end

  defp maybe_attach_failure_context(issue, false), do: issue

  defp maybe_attach_failure_context(issue, true) when is_map(issue) do
    case issue_failure_context(issue) do
      nil ->
        issue

      context ->
        summary = issue_failure_context_summary(context)

        issue
        |> put_prompt_issue_field("failure_context", context)
        |> put_prompt_issue_field("failure_summary", summary)
        |> append_failure_summary_to_description(summary)
    end
  end

  defp maybe_attach_failure_context(issue, _include_failure_context?), do: issue

  defp issue_failure_context(issue) when is_map(issue) do
    internal_context =
      issue
      |> issue_internal_metadata()
      |> internal_last_failure_context()

    case internal_context do
      nil -> fallback_failure_context(issue)
      context -> context
    end
  end

  defp issue_failure_context(_issue), do: nil

  defp issue_internal_metadata(issue) do
    case field(issue, :internal_metadata) do
      metadata when is_map(metadata) ->
        metadata

      _other ->
        case field(issue, :internalMetadata) do
          metadata when is_map(metadata) -> metadata
          _other -> %{}
        end
    end
  end

  defp internal_last_failure_context(metadata) when is_map(metadata) do
    case field(metadata, :lastFailure) || field(metadata, :last_failure) do
      value when is_map(value) ->
        normalized_failure_context(
          field(value, :reason),
          field(value, :attempt),
          field(value, :recordedAt) || field(value, :recorded_at),
          field(value, :status)
        )

      _other ->
        nil
    end
  end

  defp internal_last_failure_context(_metadata), do: nil

  defp fallback_failure_context(issue) when is_map(issue) do
    normalized_failure_context(
      field(issue, :last_error) || field(issue, :lastError),
      field(issue, :last_run_attempt) || field(issue, :lastRunAttempt),
      nil,
      nil
    )
  end

  defp fallback_failure_context(_issue), do: nil

  defp normalized_failure_context(reason, attempt, recorded_at, status) do
    context =
      %{}
      |> maybe_put_context_field("reason", normalized_string(reason))
      |> maybe_put_context_field("attempt", normalized_integer(attempt))
      |> maybe_put_context_field("recorded_at", normalized_string(recorded_at))
      |> maybe_put_context_field("status", normalized_string(status))

    if map_size(context) == 0, do: nil, else: context
  end

  defp issue_failure_context_summary(context) when is_map(context) do
    reason = Map.get(context, "reason")
    attempt = Map.get(context, "attempt")
    status = Map.get(context, "status")
    recorded_at = Map.get(context, "recorded_at")

    attempt_fragment =
      if is_integer(attempt), do: "attempt #{attempt}", else: "previous attempt"

    status_fragment =
      if is_binary(status), do: " (status: #{status})", else: ""

    recorded_fragment =
      if is_binary(recorded_at), do: " at #{recorded_at}", else: ""

    reason_fragment =
      if is_binary(reason), do: reason, else: "reason unavailable"

    "#{attempt_fragment}#{status_fragment} failed#{recorded_fragment}: #{reason_fragment}"
  end

  defp issue_failure_context_summary(_context), do: "previous attempt failed"

  defp append_failure_summary_to_description(issue, summary)
       when is_map(issue) and is_binary(summary) and summary != "" do
    existing_description = normalized_string(field(issue, :description)) || ""
    failure_section = "Previous failure context:\n- #{summary}"

    next_description =
      cond do
        existing_description == "" ->
          failure_section

        String.contains?(existing_description, failure_section) ->
          existing_description

        true ->
          "#{existing_description}\n\n#{failure_section}"
      end

    put_prompt_issue_field(issue, "description", next_description)
  end

  defp append_failure_summary_to_description(issue, _summary), do: issue

  defp put_prompt_issue_field(issue, field_name, value)
       when is_map(issue) and is_binary(field_name) do
    issue = Map.put(issue, field_name, value)

    case field_name do
      "description" -> Map.delete(issue, :description)
      "failure_context" -> Map.delete(issue, :failure_context)
      "failure_summary" -> Map.delete(issue, :failure_summary)
      _other -> issue
    end
  end

  defp put_prompt_issue_field(issue, _field_name, _value), do: issue

  defp maybe_put_context_field(map, _key, nil), do: map
  defp maybe_put_context_field(map, key, value), do: Map.put(map, key, value)

  defp normalized_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalized_string(_value), do: nil

  defp normalized_integer(value) when is_integer(value), do: value

  defp normalized_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp normalized_integer(_value), do: nil

  defp strip_testing_notes(issue) when is_map(issue) do
    Map.drop(issue, [:testing_notes, :testingNotes, "testing_notes", "testingNotes"])
  end

  defp strip_testing_notes(issue), do: issue

  defp testing_notes(issue) do
    issue
    |> raw_testing_notes()
    |> optional_string()
    |> Kernel.||("")
  end

  defp raw_testing_notes(issue) do
    case field(issue, :testing_notes) do
      nil -> field(issue, :testingNotes)
      value -> value
    end
  end

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp default_on_event(_event), do: :ok
end
