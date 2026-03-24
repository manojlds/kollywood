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
      state = %{
        issue: issue,
        issue_id: issue_meta.id,
        identifier: issue_meta.identifier,
        started_at: started_at,
        workspace: nil,
        session: nil,
        turn_count: 0,
        last_output: nil,
        events_rev: [],
        on_event: on_event,
        attempt: attempt
      }

      state = emit(state, :run_started, %{attempt: attempt, mode: mode, turn_limit: turn_limit})

      case Workspace.create_for_issue(issue_meta.identifier, config) do
        {:ok, workspace} ->
          state =
            state
            |> Map.put(:workspace, workspace)
            |> emit(:workspace_ready, %{workspace_path: workspace.path})

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

        case stop_session(run_state, session) do
          {:ok, stopped_state} ->
            if is_nil(reason) do
              case finalize_with_quality_gates(stopped_state, config, status) do
                {:ok, qualified_state} ->
                  succeed(qualified_state, status)

                {:error, gate_reason, qualified_state} ->
                  fail(qualified_state, gate_reason)
              end
            else
              fail(stopped_state, reason)
            end

          {:error, stop_reason, stopped_state} ->
            combined_reason =
              combine_errors(reason, "Failed to stop agent session: #{stop_reason}")

            fail(stopped_state, combined_reason)
        end

      {:error, reason} ->
        fail(state, "Failed to start agent session: #{reason}")
    end
  end

  defp run_turns(state, config, prompt_template, mode, turn_limit, turn_opts) do
    turn_number = state.turn_count + 1

    with {:ok, prompt} <- build_prompt(state, prompt_template, turn_number),
         :ok <- Workspace.before_run(state.workspace, config.hooks) do
      state =
        state
        |> Map.put(:turn_count, turn_number)
        |> emit(:turn_started, %{turn: turn_number})

      turn_result = Agent.run_turn(state.session, prompt, turn_opts)
      Workspace.after_run(state.workspace, config.hooks)

      case turn_result do
        {:ok, result} ->
          state =
            state
            |> Map.put(:last_output, result.output)
            |> emit(:turn_succeeded, %{turn: turn_number, duration_ms: result.duration_ms})

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

  defp build_prompt(state, prompt_template, 1) do
    variables = PromptBuilder.build_variables(state.issue, state.attempt)

    case PromptBuilder.render(prompt_template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "Failed to render initial prompt: #{reason}"}
    end
  end

  defp build_prompt(state, _prompt_template, turn_number) do
    {:ok, ContinuationPrompt.build(state.issue, turn_number)}
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

  defp finalize_with_quality_gates(state, config, _status) do
    with {:ok, state} <- run_required_checks(state, config),
         {:ok, state} <- run_review_if_enabled(state, config) do
      {:ok, state}
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
          timeout_ms = checks_timeout_ms(config)
          fail_fast = checks_fail_fast?(config)

          state =
            emit(state, :checks_started, %{
              check_count: length(commands),
              timeout_ms: timeout_ms,
              fail_fast: fail_fast
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

                case execute_check_command(workspace_path, command, timeout_ms) do
                  {:ok, duration_ms} ->
                    {
                      emit(acc_state, :check_passed, %{
                        check_index: index,
                        command: command,
                        duration_ms: duration_ms
                      }),
                      acc_errors
                    }

                  {:error, reason, duration_ms, output_preview} ->
                    error_message =
                      "check ##{index} failed (#{command}): #{reason}#{preview_suffix(output_preview)}"

                    {
                      emit(acc_state, :check_failed, %{
                        check_index: index,
                        command: command,
                        reason: reason,
                        duration_ms: duration_ms,
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
            {:error, reason, emit(state, :checks_failed, %{error_count: length(errors)})}
          end
      end
    end
  end

  defp run_review_if_enabled(state, config) do
    if review_enabled?(config) do
      review_agent_kind = review_agent_kind(config)
      state = emit(state, :review_started, %{agent_kind: review_agent_kind})

      with {:ok, prompt} <- build_review_prompt(state, config),
           {:ok, output} <- run_review_turn(state, config, prompt),
           :ok <- validate_review_output(output, config) do
        {:ok, emit(state, :review_passed, %{agent_kind: review_agent_kind})}
      else
        {:error, reason} ->
          {:error, "review failed: #{reason}", emit(state, :review_failed, %{reason: reason})}
      end
    else
      {:ok, state}
    end
  end

  defp execute_check_command(workspace_path, command, timeout_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    try do
      task =
        Task.async(fn ->
          System.cmd("bash", ["-lc", command], cd: workspace_path, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {_output, 0}} ->
          {:ok, elapsed_ms(started_at_ms)}

        {:ok, {output, exit_code}} ->
          {:error, "exit code #{exit_code}", elapsed_ms(started_at_ms), output_preview(output)}

        nil ->
          {:error, "timed out after #{timeout_ms}ms", elapsed_ms(started_at_ms), ""}
      end
    rescue
      error ->
        {:error, Exception.message(error), elapsed_ms(started_at_ms), ""}
    end
  end

  defp run_review_turn(state, config, prompt) do
    review_config = reviewer_config(config)

    case Agent.start_session(review_config, state.workspace, %{}) do
      {:ok, session} ->
        turn_result = Agent.run_turn(session, prompt, %{})
        stop_result = Agent.stop_session(session)
        normalize_review_turn_result(turn_result, stop_result)

      {:error, reason} ->
        {:error, "failed to start reviewer session: #{reason}"}
    end
  end

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

  defp validate_review_output(output, config) do
    pass_token = review_pass_token(config)
    fail_token = review_fail_token(config)

    first_line =
      output
      |> String.split("\n", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()

    cond do
      String.starts_with?(first_line, pass_token) ->
        :ok

      String.starts_with?(first_line, fail_token) ->
        reason =
          first_line
          |> String.replace_prefix(fail_token, "")
          |> String.trim()
          |> String.trim_leading(":")
          |> String.trim()

        if reason == "" do
          {:error, "reviewer rejected changes"}
        else
          {:error, reason}
        end

      true ->
        {:error,
         "reviewer must start first line with #{pass_token} or #{fail_token}; got: #{inspect(first_line)}"}
    end
  end

  defp build_review_prompt(state, config) do
    pass_token = review_pass_token(config)
    fail_token = review_fail_token(config)
    template = review_prompt_template(config)

    variables =
      PromptBuilder.build_variables(state.issue, state.attempt)
      |> Map.put("pass_token", pass_token)
      |> Map.put("fail_token", fail_token)
      |> Map.put("agent_output", state.last_output || "")

    case PromptBuilder.render(template, variables) do
      {:ok, prompt} -> {:ok, prompt}
      {:error, reason} -> {:error, "failed to render review prompt: #{reason}"}
    end
  end

  defp reviewer_config(config) do
    review_agent = get_in(config, [Access.key(:review, %{}), Access.key(:agent, %{})]) || %{}
    base_agent = Map.get(config, :agent, %{})

    merged_agent = %{
      kind: Map.get(review_agent, :kind, Map.get(base_agent, :kind)),
      max_concurrent_agents: Map.get(base_agent, :max_concurrent_agents, 1),
      max_turns: 1,
      max_retry_backoff_ms: Map.get(base_agent, :max_retry_backoff_ms, 300_000),
      command: Map.get(review_agent, :command, Map.get(base_agent, :command)),
      args: Map.get(review_agent, :args, Map.get(base_agent, :args, [])),
      env: Map.merge(Map.get(base_agent, :env, %{}), Map.get(review_agent, :env, %{})),
      timeout_ms:
        positive_integer(
          Map.get(review_agent, :timeout_ms, Map.get(base_agent, :timeout_ms, 300_000)),
          300_000
        )
    }

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
    |> Map.get(:timeout_ms, 300_000)
    |> positive_integer(300_000)
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

  defp review_pass_token(config) do
    config
    |> review_config()
    |> Map.get(:pass_token, "REVIEW_PASS")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "REVIEW_PASS"
      value -> value
    end
  end

  defp review_fail_token(config) do
    config
    |> review_config()
    |> Map.get(:fail_token, "REVIEW_FAIL")
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "REVIEW_FAIL"
      value -> value
    end
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

  defp review_prompt_template(config) do
    case get_in(config, [Access.key(:review, %{}), Access.key(:prompt_template)]) do
      value when is_binary(value) and value != "" ->
        value

      _other ->
        """
        You are reviewing work for issue {{ issue.identifier }}: {{ issue.title }}.

        Issue description:
        {{ issue.description }}

        Prior implementation output (may be empty):
        {{ agent_output }}

        Review the current workspace changes. You may run commands for validation.
        Do not modify files, do not commit, and do not push.

        On the FIRST line, return exactly one verdict:
        {{ pass_token }}
        or
        {{ fail_token }}: <short reason>

        After the first line, include a concise review summary.
        """
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

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp default_on_event(_event), do: :ok
end
