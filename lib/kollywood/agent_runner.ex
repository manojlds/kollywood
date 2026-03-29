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
  Retries a failed terminal step (`checks`, `review`, or `publish`) using an
  existing workspace and skipping agent turns.
  """
  @spec retry_step(map(), :checks | :review | :publish, run_opts()) ::
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

      finalize_run_with_runtime(outcome)
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
         {:ok, state} <- run_publish(state, config) do
      {:ok, state}
    else
      {:checks_failed, reason, state} -> {:error, reason, state}
      {:review_failed, reason, state} -> {:error, reason, state}
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
         {:ok, state} <- run_publish(state, config) do
      {:ok, state}
    else
      {:review_failed, reason, state} -> {:error, reason, state}
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

        finalize_run_with_runtime(outcome)

      {:error, reason} ->
        fail(state, "Failed to start agent session: #{reason}")
    end
  end

  defp finalize_run_with_runtime({:ok, status, state}) do
    case maybe_stop_runtime(state) do
      {:ok, stopped_state} ->
        succeed(stopped_state, status)

      {:error, reason, stopped_state} ->
        fail(stopped_state, reason)
    end
  end

  defp finalize_run_with_runtime({:error, reason, state}) do
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
         :ok <- Workspace.before_run(state.workspace, config.hooks) do
      state =
        state
        |> Map.put(:turn_count, turn_number)
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
    variables = PromptBuilder.build_variables(state.issue, state.attempt)
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

            :auto_merge when provider == :local ->
              run_publish_auto_merge_local(state, config, workspace)

            :auto_merge when provider in [:github, :gitlab] ->
              run_publish_auto_merge_remote(state, config, workspace, provider)

            :auto_merge ->
              {:error,
               "publish.mode auto_merge requires provider local, github, or gitlab (got: #{inspect(provider)})",
               emit(state, :publish_failed, %{
                 branch: workspace.branch,
                 reason: "unsupported provider"
               })}
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

  defp run_publish_auto_merge_remote(state, config, workspace, provider) do
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

  defp run_publish_auto_merge_local(state, config, workspace) do
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
        with :ok <- Workspace.before_run(state.workspace, config.hooks) do
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

    run_quality_cycle(
      state,
      config,
      session_opts,
      turn_opts,
      prompt_template,
      1,
      quality_limit,
      checks_limit,
      review_limit
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
         review_limit
       ) do
    state =
      emit(state, :quality_cycle_started, %{
        cycle: cycle,
        max_cycles: quality_limit,
        checks_max_cycles: checks_limit,
        review_max_cycles: review_limit
      })

    with {:ok, state} <- run_required_checks(state, config),
         {:ok, state} <- run_review_if_enabled(state, config, cycle) do
      {:ok, emit(state, :quality_cycle_passed, %{cycle: cycle})}
    else
      {:checks_failed, reason, state} when cycle < checks_limit ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: quality_limit,
            checks_max_cycles: checks_limit,
            review_max_cycles: review_limit,
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
              review_limit
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
              review_limit
            )

          {:error, remediation_reason, state} ->
            {:error, "review remediation failed: #{remediation_reason}", state}
        end

      {:review_failed, reason, state} ->
        {:error, "review failed after #{review_limit} cycle(s): #{reason}", state}

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
           {:ok, _output} <- run_review_turn(state, config, prompt, state.log_files) do
        persist_review_json(workspace_rjp, state.log_files)

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
        with :ok <- Workspace.before_run(state.workspace, config.hooks) do
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
        with :ok <- Workspace.before_run(state.workspace, config.hooks) do
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
    base_variables = PromptBuilder.build_variables(state.issue, state.attempt)

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

  defp ensure_runtime_for_checks(state) do
    runtime = state.runtime

    if runtime.profile == :checks_only or runtime.started? do
      {:ok, state}
    else
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
    |> Map.get(:profile, :checks_only)
  end

  defp runtime_kind(config) do
    config
    |> Map.get(:runtime, %{})
    |> Map.get(:kind, :host)
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

  defp with_raw_log(opts, %{agent_stdout: path}, :agent_stdout) when is_binary(path),
    do: Map.put(opts, :raw_log, path)

  defp with_raw_log(opts, %{reviewer_stdout: path}, :reviewer_stdout) when is_binary(path),
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

  defp reset_review_json(path) when is_binary(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, "failed to reset review.json: #{inspect(reason)}"}
    end
  end

  defp reset_review_json(_path), do: {:error, "review_json path not configured"}

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
      PromptBuilder.build_variables(state.issue, state.attempt)
      |> Map.put("review_json_path", rjp)
      |> Map.put("cycle", cycle)

    case PromptBuilder.render(template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render review prompt: #{reason}"}
    end
  end

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

  defp persist_review_json(src, %{review_json: dest}) when is_binary(dest) do
    File.copy(src, dest)
    :ok
  end

  defp persist_review_json(_src, _log_files), do: :ok

  defp build_review_remediation_prompt(state, review_feedback, cycle, prompt_template) do
    base_variables = PromptBuilder.build_variables(state.issue, state.attempt)

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

  defp review_agent_kind(config) do
    config
    |> review_config()
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

  defp review_prompt_template(config) do
    case config |> review_config() |> Map.get(:prompt_template) do
      value when is_binary(value) and value != "" -> value
      _other -> @default_review_prompt_template
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

  defp parse_retry_step(step) when step in [:checks, :review, :publish], do: {:ok, step}

  defp parse_retry_step(_step),
    do: {:error, "retry step must be one of: :checks, :review, :publish"}

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
