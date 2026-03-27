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
  alias Kollywood.WorkflowStore
  alias Kollywood.Workspace

  @type mode :: :single_turn | :max_turns

  @type run_opt ::
          {:workflow_store, GenServer.server()}
          | {:config, Config.t()}
          | {:prompt_template, String.t()}
          | {:attempt, non_neg_integer() | nil}
          | {:mode, mode()}
          | {:turn_limit, pos_integer()}
          | {:session_opts, map() | keyword()}
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
         {:ok, config, prompt_template} <- resolve_workflow(opts),
         {:ok, mode} <- parse_mode(Keyword.get(opts, :mode, :single_turn)),
         {:ok, turn_limit} <- parse_turn_limit(config, Keyword.get(opts, :turn_limit)),
         {:ok, session_opts} <-
           normalize_opts(Keyword.get(opts, :session_opts, %{}), "session_opts"),
         {:ok, turn_opts} <- normalize_opts(Keyword.get(opts, :turn_opts, %{}), "turn_opts") do
      log_files = Keyword.get(opts, :log_files)

      state = %{
        issue: issue,
        issue_id: issue_meta.id,
        identifier: issue_meta.identifier,
        started_at: started_at,
        workspace: nil,
        runtime: default_runtime_state(config),
        session: nil,
        turn_count: 0,
        last_output: nil,
        events_rev: [],
        on_event: on_event,
        attempt: attempt,
        log_files: log_files
      }

      state = emit(state, :run_started, %{attempt: attempt, mode: mode, turn_limit: turn_limit})

      case Workspace.create_for_issue(issue_meta.identifier, config) do
        {:ok, workspace} ->
          runtime = runtime_for_workspace(config, workspace)

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

    # Check for existing work in workspace
    resume_context = detect_resume_context(state.workspace)

    # Add resume context to variables if work exists
    variables =
      if resume_context != "" do
        Map.put(variables, "resume_context", resume_context)
      else
        variables
      end

    case build_task_prompt(prompt_template, variables, config) do
      {:ok, prompt} -> {:ok, prompt}
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
    commands = get_in(config, [Access.key(:checks, %{}), Access.key(:required, [])]) || []

    case commands do
      [] ->
        ""

      cmds ->
        list = Enum.map_join(cmds, "\n", fn cmd -> "- `#{cmd}`" end)

        "\n\n## Verification\n\nRun these commands to verify your changes before finishing:\n#{list}"
    end
  end

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
    auto_push = get_in(config, [Access.key(:publish, %{}), Access.key(:auto_push, :never)])

    with {:ok, ahead} <- Workspace.commits_ahead(workspace),
         :ok <- check_commit_requirement(auto_push, ahead) do
      case {auto_push, ahead} do
        {:on_pass, count} when is_integer(count) and count > 0 ->
          state = emit(state, :publish_started, %{branch: workspace.branch, auto_push: auto_push})

          case Workspace.push_branch(workspace) do
            :ok ->
              state =
                state
                |> emit(:publish_push_succeeded, %{branch: workspace.branch})
                |> maybe_auto_merge_local(config, workspace)

              run_create_pr(state, config, workspace)

            {:error, reason} ->
              {:error, "push failed: #{reason}",
               emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
          end

        _ ->
          {:ok, emit(state, :publish_skipped, %{branch: workspace.branch, auto_push: auto_push})}
      end
    else
      {:error, reason} ->
        {:error, reason,
         emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
    end
  end

  defp maybe_auto_merge_local(state, config, workspace) do
    auto_merge = get_in(config, [Access.key(:publish, %{}), Access.key(:auto_merge, :never)])
    provider = Config.effective_publish_provider(config)

    if auto_merge == :on_pass and provider == :local do
      base_branch = get_in(config, [Access.key(:git, %{}), Access.key(:base_branch)]) || "main"

      case Workspace.merge_branch_to_main(workspace, base_branch) do
        :ok ->
          emit(state, :publish_merged, %{branch: workspace.branch, base_branch: base_branch})

        {:error, reason} ->
          Logger.warning(
            "publish auto-merge failed for branch #{workspace.branch} -> #{base_branch}: #{reason}"
          )

          emit(state, :publish_merge_failed, %{
            branch: workspace.branch,
            base_branch: base_branch,
            reason: reason
          })
      end
    else
      state
    end
  end

  defp run_create_pr(state, config, workspace) do
    provider = Config.effective_publish_provider(config)
    pr_opts = Publisher.pr_opts(config, state.issue)

    cond do
      is_nil(pr_opts) ->
        {:ok, emit(state, :publish_succeeded, %{branch: workspace.branch, pr_url: nil})}

      provider in [:local, nil] ->
        {:ok,
         emit(state, :publish_succeeded, %{
           branch: workspace.branch,
           pr_url: nil,
           note: "push complete — PR creation skipped (no git provider configured)"
         })}

      true ->
        case Publisher.module_for_provider(provider) do
          {:ok, adapter} ->
            case adapter.create_pr(workspace, pr_opts) do
              {:ok, url} ->
                {:ok, emit(state, :publish_succeeded, %{branch: workspace.branch, pr_url: url})}

              {:error, reason} ->
                {:error, "PR creation failed: #{reason}",
                 emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
            end

          {:error, reason} ->
            {:error, reason,
             emit(state, :publish_failed, %{branch: workspace.branch, reason: reason})}
        end
    end
  end

  defp check_commit_requirement(:on_pass, 0) do
    {:error, "no commits found on branch — agent did not commit any changes"}
  end

  defp check_commit_requirement(_auto_push, _ahead), do: :ok

  defp finalize_with_quality_gates(
         state,
         config,
         _status,
         session_opts,
         turn_opts,
         prompt_template
       ) do
    max_cycles = review_max_cycles(config)

    run_quality_cycle(state, config, session_opts, turn_opts, prompt_template, 1, max_cycles)
  end

  defp run_quality_cycle(
         state,
         config,
         session_opts,
         turn_opts,
         prompt_template,
         cycle,
         max_cycles
       ) do
    state = emit(state, :quality_cycle_started, %{cycle: cycle, max_cycles: max_cycles})

    with {:ok, state} <- run_required_checks(state, config),
         {:ok, state} <- run_review_if_enabled(state, config, cycle) do
      {:ok, emit(state, :quality_cycle_passed, %{cycle: cycle})}
    else
      {:checks_failed, reason, state} when cycle < max_cycles ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: max_cycles,
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
              max_cycles
            )

          {:error, remediation_reason, state} ->
            {:error, "checks remediation failed: #{remediation_reason}", state}
        end

      {:checks_failed, reason, state} ->
        {:error, "checks failed after #{max_cycles} cycle(s): #{reason}", state}

      {:review_failed, reason, state} when cycle < max_cycles ->
        state =
          emit(state, :quality_cycle_retrying, %{
            cycle: cycle,
            max_cycles: max_cycles,
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
              max_cycles
            )

          {:error, remediation_reason, state} ->
            {:error, "review remediation failed: #{remediation_reason}", state}
        end

      {:review_failed, reason, state} ->
        {:error, "review failed after #{max_cycles} cycle(s): #{reason}", state}

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

      with {:ok, prompt} <- build_review_prompt(state, config, cycle, workspace_rjp),
           {:ok, _output} <- run_review_turn(state, config, prompt, state.log_files),
           {:ok, verdict} <- read_review_json(workspace_rjp) do
        persist_review_json(workspace_rjp, state.log_files)

        case verdict do
          :pass ->
            {:ok, emit(state, :review_passed, %{agent_kind: review_agent_kind, cycle: cycle})}

          {:fail, feedback} ->
            {:review_failed, feedback,
             emit(state, :review_failed, %{
               agent_kind: review_agent_kind,
               cycle: cycle,
               reason: feedback
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

  defp execute_check_command(workspace_path, command, timeout_ms, runtime) do
    {executable, args, env} = check_command_invocation(command, runtime)

    case execute_command(executable, args, workspace_path, env, timeout_ms) do
      {:ok, output, duration_ms} ->
        {:ok, duration_ms, output}

      {:error, reason, output, duration_ms} ->
        {:error, reason, duration_ms, output}
    end
  end

  defp ensure_runtime_for_checks(state) do
    runtime = state.runtime || default_runtime_state(nil)

    case runtime.profile do
      :checks_only ->
        {:ok, state}

      :full_stack ->
        if runtime.started? do
          {:ok, state}
        else
          state =
            emit(state, :runtime_starting, %{
              runtime_profile: :full_stack,
              command: runtime.command,
              workspace_path: runtime.workspace_path,
              process_count: length(runtime.processes)
            })

          with {:ok, runtime} <- ensure_runtime_isolation(runtime) do
            state = Map.put(state, :runtime, runtime)

            case execute_command(
                   runtime.command,
                   runtime_start_args(runtime),
                   runtime.workspace_path,
                   runtime.env,
                   runtime.start_timeout_ms
                 ) do
              {:ok, output, duration_ms} ->
                runtime = %{runtime | started?: true, process_state: :running}

                state =
                  state
                  |> Map.put(:runtime, runtime)
                  |> emit(:runtime_started, %{
                    runtime_profile: :full_stack,
                    duration_ms: duration_ms,
                    workspace_path: runtime.workspace_path,
                    command: runtime.command,
                    process_count: length(runtime.processes),
                    port_offset: runtime.port_offset,
                    resolved_ports: runtime.resolved_ports,
                    output: output
                  })

                {:ok, state}

              {:error, reason, output, duration_ms} ->
                output_preview = output_preview(output)
                runtime = %{runtime | process_state: :start_failed}

                state =
                  state
                  |> Map.put(:runtime, runtime)
                  |> emit(:runtime_start_failed, %{
                    runtime_profile: :full_stack,
                    duration_ms: duration_ms,
                    workspace_path: runtime.workspace_path,
                    command: runtime.command,
                    reason: reason,
                    output: output,
                    output_preview: output_preview
                  })

                {:error,
                 "failed to start runtime processes: #{reason}#{preview_suffix(output_preview)}",
                 state}
            end
          else
            {:error, reason} ->
              runtime = %{runtime | process_state: :isolation_failed}

              state =
                state
                |> Map.put(:runtime, runtime)
                |> emit(:runtime_start_failed, %{
                  runtime_profile: :full_stack,
                  duration_ms: 0,
                  workspace_path: runtime.workspace_path,
                  command: runtime.command,
                  reason: reason,
                  output_preview: ""
                })

              {:error, "failed to start runtime processes: #{reason}", state}
          end
        end
    end
  end

  defp maybe_stop_runtime(state) do
    runtime = state.runtime || default_runtime_state(nil)

    cond do
      runtime.profile != :full_stack ->
        {:ok, state}

      not runtime_stop_required?(runtime) ->
        runtime = release_runtime_offset(runtime)
        {:ok, Map.put(state, :runtime, runtime)}

      true ->
        state =
          emit(state, :runtime_stopping, %{
            runtime_profile: :full_stack,
            command: runtime.command,
            workspace_path: runtime.workspace_path
          })

        case execute_command(
               runtime.command,
               runtime_stop_args(runtime),
               runtime.workspace_path,
               runtime.env,
               runtime.stop_timeout_ms
             ) do
          {:ok, output, duration_ms} ->
            runtime =
              runtime
              |> Map.put(:started?, false)
              |> Map.put(:process_state, :stopped)
              |> release_runtime_offset()

            state =
              state
              |> Map.put(:runtime, runtime)
              |> emit(:runtime_stopped, %{
                runtime_profile: :full_stack,
                duration_ms: duration_ms,
                workspace_path: runtime.workspace_path,
                command: runtime.command,
                output: output
              })

            {:ok, state}

          {:error, reason, output, duration_ms} ->
            output_preview = output_preview(output)

            runtime =
              runtime
              |> Map.put(:process_state, :stop_failed)
              |> release_runtime_offset()

            state =
              state
              |> Map.put(:runtime, runtime)
              |> emit(:runtime_stop_failed, %{
                runtime_profile: :full_stack,
                duration_ms: duration_ms,
                workspace_path: runtime.workspace_path,
                command: runtime.command,
                reason: reason,
                output: output,
                output_preview: output_preview
              })

            {:error,
             "failed to stop runtime processes: #{reason}#{preview_suffix(output_preview)}",
             state}
        end
    end
  end

  defp runtime_stop_required?(runtime) do
    runtime.started? == true or runtime.process_state == :start_failed
  end

  defp ensure_runtime_isolation(runtime) do
    case Map.get(runtime, :offset_lease_name) do
      lease_name when not is_nil(lease_name) ->
        {:ok, runtime}

      _other ->
        reserve_runtime_offset(runtime)
    end
  end

  defp reserve_runtime_offset(runtime) do
    modulus = positive_integer(Map.get(runtime, :port_offset_mod), 1000)

    workspace_identity =
      Map.get(runtime, :workspace_identity) || Map.get(runtime, :workspace_path) ||
        Map.get(runtime, :workspace_key)

    seed_offset = runtime_port_offset_seed(workspace_identity, modulus)

    case runtime_offset_lease(modulus, seed_offset) do
      {:ok, port_offset, lease_name} ->
        port_bases = Map.get(runtime, :port_bases, %{})
        user_env = Map.get(runtime, :user_env, %{})
        workspace_key = Map.get(runtime, :workspace_key)
        workspace_path = Map.get(runtime, :workspace_path)
        resolved_ports = runtime_resolved_ports(port_bases, port_offset)
        env = runtime_env(workspace_key, workspace_path, user_env, port_offset, resolved_ports)

        {:ok,
         runtime
         |> Map.put(:port_offset_seed, seed_offset)
         |> Map.put(:port_offset, port_offset)
         |> Map.put(:resolved_ports, resolved_ports)
         |> Map.put(:env, env)
         |> Map.put(:offset_lease_name, lease_name)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp runtime_offset_lease(modulus, seed_offset) do
    0..(modulus - 1)
    |> Enum.reduce_while(:none, fn probe, _acc ->
      offset = rem(seed_offset + probe, modulus)
      lease_name = runtime_offset_lease_name(modulus, offset)

      case :global.register_name(lease_name, self()) do
        :yes -> {:halt, {:ok, offset, lease_name}}
        :no -> {:cont, :none}
      end
    end)
    |> case do
      {:ok, _offset, _lease_name} = ok ->
        ok

      :none ->
        {:error,
         "no available runtime port offsets within modulus #{modulus}; increase runtime.full_stack.port_offset_mod or reduce concurrent full_stack runs"}
    end
  end

  defp release_runtime_offset(runtime) do
    case Map.get(runtime, :offset_lease_name) do
      lease_name when is_nil(lease_name) ->
        runtime

      lease_name ->
        release_runtime_offset_lease(lease_name)
        Map.put(runtime, :offset_lease_name, nil)
    end
  end

  defp release_runtime_offset_lease(lease_name) do
    case :global.whereis_name(lease_name) do
      pid when pid == self() ->
        :global.unregister_name(lease_name)

      _other ->
        :ok
    end

    :ok
  end

  defp runtime_offset_lease_name(modulus, offset) do
    {:kollywood, :runtime_port_offset, modulus, offset}
  end

  defp check_command_invocation(command, %{profile: :full_stack} = runtime) do
    {runtime.command, ["shell", "--", "bash", "-lc", command], runtime.env}
  end

  defp check_command_invocation(command, _runtime) do
    {"bash", ["-lc", command], %{}}
  end

  defp runtime_start_args(runtime) do
    base = ["processes", "up", "--detach", "--strict-ports"]

    if runtime.processes == [] do
      base
    else
      base ++ runtime.processes
    end
  end

  defp runtime_stop_args(_runtime), do: ["processes", "down"]

  defp execute_command(command, args, workspace_path, env, timeout_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    opts =
      [cd: workspace_path, stderr_to_stdout: true]
      |> maybe_put_env(env)

    try do
      task = Task.async(fn -> System.cmd(command, args, opts) end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {output, 0}} ->
          {:ok, output, elapsed_ms(started_at_ms)}

        {:ok, {output, exit_code}} ->
          {:error, "exit code #{exit_code}", output, elapsed_ms(started_at_ms)}

        nil ->
          {:error, "timed out after #{timeout_ms}ms", "", elapsed_ms(started_at_ms)}
      end
    rescue
      error ->
        {:error, Exception.message(error), "", elapsed_ms(started_at_ms)}
    end
  end

  defp maybe_put_env(opts, env) when map_size(env) == 0, do: opts
  defp maybe_put_env(opts, env), do: Keyword.put(opts, :env, env_to_cmd_env(env))

  defp env_to_cmd_env(env) when is_map(env), do: Enum.to_list(env)
  defp env_to_cmd_env(_env), do: []

  defp runtime_profile_from_state(state) do
    state
    |> Map.get(:runtime, %{})
    |> Map.get(:profile, :checks_only)
  end

  defp default_runtime_state(config) do
    case runtime_profile(config) do
      :full_stack ->
        %{
          profile: :full_stack,
          process_state: :pending,
          started?: false,
          command: "devenv",
          processes: [],
          env: %{},
          user_env: %{},
          port_bases: %{},
          resolved_ports: %{},
          port_offset: 0,
          port_offset_mod: 1000,
          port_offset_seed: 0,
          offset_lease_name: nil,
          start_timeout_ms: 120_000,
          stop_timeout_ms: 60_000,
          workspace_key: nil,
          workspace_identity: nil,
          workspace_path: nil
        }

      :checks_only ->
        %{
          profile: :checks_only,
          process_state: :not_required,
          started?: false,
          command: nil,
          processes: [],
          env: %{},
          user_env: %{},
          port_bases: %{},
          resolved_ports: %{},
          port_offset: 0,
          port_offset_mod: 1000,
          port_offset_seed: 0,
          offset_lease_name: nil,
          start_timeout_ms: 120_000,
          stop_timeout_ms: 60_000,
          workspace_key: nil,
          workspace_identity: nil,
          workspace_path: nil
        }
    end
  end

  defp runtime_for_workspace(config, workspace) do
    workspace_key = Map.get(workspace, :key) || Path.basename(workspace.path)
    workspace_path = workspace.path
    workspace_identity = runtime_workspace_identity(workspace_key, workspace_path)

    case runtime_profile(config) do
      :checks_only ->
        %{
          default_runtime_state(config)
          | workspace_key: workspace_key,
            workspace_identity: workspace_identity,
            workspace_path: workspace_path
        }

      :full_stack ->
        full_stack = runtime_full_stack_config(config)
        user_env = runtime_env_map(field(full_stack, :env))
        port_bases = runtime_ports_map(field(full_stack, :ports))
        port_offset_mod = positive_integer(field(full_stack, :port_offset_mod), 1000)
        port_offset_seed = runtime_port_offset_seed(workspace_identity, port_offset_mod)
        resolved_ports = runtime_resolved_ports(port_bases, port_offset_seed)

        %{
          profile: :full_stack,
          process_state: :pending,
          started?: false,
          command: optional_string(field(full_stack, :command)) || "devenv",
          processes: runtime_processes(field(full_stack, :processes)),
          env:
            runtime_env(workspace_key, workspace_path, user_env, port_offset_seed, resolved_ports),
          user_env: user_env,
          port_bases: port_bases,
          resolved_ports: resolved_ports,
          port_offset: port_offset_seed,
          port_offset_mod: port_offset_mod,
          port_offset_seed: port_offset_seed,
          offset_lease_name: nil,
          start_timeout_ms: positive_integer(field(full_stack, :start_timeout_ms), 120_000),
          stop_timeout_ms: positive_integer(field(full_stack, :stop_timeout_ms), 60_000),
          workspace_key: workspace_key,
          workspace_identity: workspace_identity,
          workspace_path: workspace_path
        }
    end
  end

  defp runtime_profile(config) do
    case field(runtime_config(config), :profile) do
      :full_stack -> :full_stack
      "full_stack" -> :full_stack
      _other -> :checks_only
    end
  end

  defp runtime_config(config), do: Map.get(config || %{}, :runtime) || %{}

  defp runtime_full_stack_config(config) do
    case field(runtime_config(config), :full_stack) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp runtime_processes(value) when is_list(value) do
    value
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp runtime_processes(_value), do: []

  defp runtime_env_map(value) when is_map(value) do
    Map.new(value, fn {key, val} ->
      {to_string(key), to_string(val)}
    end)
  end

  defp runtime_env_map(_value), do: %{}

  defp runtime_ports_map(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, val}, acc ->
      case positive_integer(val, nil) do
        parsed when is_integer(parsed) and parsed > 0 -> Map.put(acc, to_string(key), parsed)
        _other -> acc
      end
    end)
  end

  defp runtime_ports_map(_value), do: %{}

  defp runtime_workspace_identity(workspace_key, workspace_path) do
    optional_string(workspace_path) || optional_string(workspace_key) || "unknown-worktree"
  end

  defp runtime_resolved_ports(port_bases, port_offset) do
    Map.new(port_bases, fn {key, base_port} ->
      {key, base_port + port_offset}
    end)
  end

  defp runtime_env(workspace_key, workspace_path, user_env, port_offset, resolved_ports) do
    builtins = %{
      "KOLLYWOOD_RUNTIME_PROFILE" => "full_stack",
      "KOLLYWOOD_RUNTIME_WORKTREE_KEY" => to_string(workspace_key),
      "KOLLYWOOD_RUNTIME_WORKTREE_PATH" => to_string(workspace_path),
      "KOLLYWOOD_RUNTIME_PORT_OFFSET" => Integer.to_string(port_offset)
    }

    port_env =
      Map.new(resolved_ports, fn {key, value} ->
        {key, Integer.to_string(value)}
      end)

    user_env
    |> Map.merge(builtins)
    |> Map.merge(port_env)
  end

  defp runtime_port_offset_seed(workspace_identity, modulus) do
    max_modulus = positive_integer(modulus, 1000)
    :erlang.phash2(to_string(workspace_identity), max(max_modulus, 1))
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

  defp review_json_path(%{review_json: path}) when is_binary(path), do: path
  defp review_json_path(_), do: nil

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
            {:error, "review.json missing valid verdict field (expected \"pass\" or \"fail\")"}

          {:error, reason} ->
            {:error, "failed to parse review.json: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, "reviewer did not write review.json"}

      {:error, reason} ->
        {:error, "failed to read review.json: #{inspect(reason)}"}
    end
  end

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
    review_agent = get_in(config, [Access.key(:review, %{}), Access.key(:agent, %{})]) || %{}
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

  defp review_max_cycles(config) do
    config
    |> review_config()
    |> Map.get(:max_cycles, 1)
    |> positive_integer(1)
  end

  defp review_agent_kind(config) do
    config
    |> review_config()
    |> get_in([Access.key(:agent, %{}), Access.key(:kind)])
    |> case do
      value when value in [:amp, :claude, :opencode, :pi] -> value
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
  - Write the file, then stop — do not print the review to stdout
  """

  @doc "Returns the default review prompt template used when none is configured in WORKFLOW.md."
  def default_review_prompt_template, do: @default_review_prompt_template

  defp review_prompt_template(config) do
    case get_in(config, [Access.key(:review, %{}), Access.key(:prompt_template)]) do
      value when is_binary(value) and value != "" -> value
      _other -> @default_review_prompt_template
    end
  end

  defp checks_config(config), do: Map.get(config, :checks) || %{}
  defp review_config(config), do: Map.get(config, :review) || %{}

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

  defp elapsed_ms(started_at_ms) do
    max(System.monotonic_time(:millisecond) - started_at_ms, 0)
  end

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

  defp resolve_workflow(opts) do
    workflow_store = Keyword.get(opts, :workflow_store, WorkflowStore)
    config = Keyword.get(opts, :config) || WorkflowStore.get_config(workflow_store)

    prompt_template =
      Keyword.get(opts, :prompt_template) || WorkflowStore.get_prompt_template(workflow_store)

    cond do
      not match?(%Config{}, config) ->
        {:error, "Workflow config is unavailable"}

      not (is_binary(prompt_template) and prompt_template != "") ->
        {:error, "Workflow prompt template is unavailable"}

      true ->
        {:ok, config, prompt_template}
    end
  end

  defp parse_mode(mode) when mode in [:single_turn, :max_turns], do: {:ok, mode}
  defp parse_mode(_mode), do: {:error, "mode must be :single_turn or :max_turns"}

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

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp default_on_event(_event), do: :ok
end
