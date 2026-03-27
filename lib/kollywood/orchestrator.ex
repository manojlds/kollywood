defmodule Kollywood.Orchestrator do
  @moduledoc """
  Stage 5 orchestrator that polls active issues and runs agents with bounded concurrency.

  Responsibilities:

  - read runtime limits from `WorkflowStore`
  - fetch active issues from a tracker adapter
  - dispatch issue runs via `Kollywood.AgentRunner`
  - reconcile running/retrying claims when issues leave active states
  - retry failed runs with exponential backoff
  """

  use GenServer
  require Logger

  alias Kollywood.AgentRunner
  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Tracker
  alias Kollywood.WorkflowStore

  @default_poll_interval_ms 5_000
  @default_max_concurrent_agents 5
  @default_max_retry_backoff_ms 300_000
  @default_retry_base_delay_ms 10_000
  @default_continuation_delay_ms 1_000

  @type state :: %__MODULE__{
          workflow_store: WorkflowStore.server() | Config.t(),
          tracker: :auto | module() | (Config.t() -> {:ok, [map()]} | {:error, String.t()}),
          runner: module() | (map(), keyword() -> {:ok, Result.t()} | {:error, Result.t()}),
          task_supervisor: pid(),
          runner_opts: keyword(),
          auto_poll: boolean(),
          poll_timer_ref: reference() | nil,
          poll_interval_ms: pos_integer(),
          max_concurrent_agents: pos_integer(),
          max_retry_backoff_ms: pos_integer(),
          retries_enabled: boolean(),
          max_attempts: pos_integer() | nil,
          retry_base_delay_ms: pos_integer(),
          continuation_delay_ms: pos_integer(),
          running: %{optional(String.t()) => map()},
          running_by_ref: %{optional(reference()) => String.t()},
          claimed: MapSet.t(String.t()),
          retry_attempts: %{optional(String.t()) => map()},
          completed: MapSet.t(String.t()),
          last_error: String.t() | nil,
          last_poll_at: DateTime.t() | nil
        }

  defstruct [
    :workflow_store,
    :tracker,
    :runner,
    :task_supervisor,
    :runner_opts,
    :auto_poll,
    :poll_timer_ref,
    :poll_interval_ms,
    :max_concurrent_agents,
    :max_retry_backoff_ms,
    :retries_enabled,
    :max_attempts,
    :retry_base_delay_ms,
    :continuation_delay_ms,
    :repo_local_path,
    :repo_default_branch,
    :last_error,
    :last_poll_at,
    running: %{},
    running_by_ref: %{},
    claimed: MapSet.new(),
    retry_attempts: %{},
    completed: MapSet.new()
  ]

  @typedoc "GenServer name or pid"
  @type server :: GenServer.server()

  @doc "Starts the orchestrator process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Triggers one poll cycle immediately."
  @spec poll_now(server()) :: :ok
  def poll_now(server \\ __MODULE__) do
    GenServer.call(server, :poll_now)
  end

  @doc "Returns a runtime status snapshot useful for dashboards and tests."
  @spec status(server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  @doc "Stops one issue run/retry claim if it is currently tracked."
  @spec stop_issue(server(), String.t()) :: :ok
  def stop_issue(server \\ __MODULE__, issue_id) when is_binary(issue_id) do
    GenServer.call(server, {:stop_issue, issue_id})
  end

  @impl true
  def init(opts) do
    with {:ok, task_supervisor} <- Task.Supervisor.start_link() do
      state = %__MODULE__{
        workflow_store: Keyword.get(opts, :workflow_store, WorkflowStore),
        tracker: Keyword.get(opts, :tracker, :auto),
        runner: Keyword.get(opts, :runner, AgentRunner),
        task_supervisor: task_supervisor,
        runner_opts: Keyword.get(opts, :runner_opts, []),
        auto_poll: Keyword.get(opts, :auto_poll, true),
        poll_timer_ref: nil,
        poll_interval_ms:
          positive_integer(Keyword.get(opts, :poll_interval_ms), @default_poll_interval_ms),
        max_concurrent_agents:
          positive_integer(
            Keyword.get(opts, :max_concurrent_agents),
            @default_max_concurrent_agents
          ),
        max_retry_backoff_ms:
          positive_integer(
            Keyword.get(opts, :max_retry_backoff_ms),
            @default_max_retry_backoff_ms
          ),
        retries_enabled: Keyword.get(opts, :retries_enabled, true),
        max_attempts: positive_integer(Keyword.get(opts, :max_attempts), nil),
        repo_local_path: Keyword.get(opts, :repo_local_path),
        repo_default_branch: Keyword.get(opts, :repo_default_branch, "main"),
        retry_base_delay_ms:
          positive_integer(Keyword.get(opts, :retry_base_delay_ms), @default_retry_base_delay_ms),
        continuation_delay_ms:
          positive_integer(
            Keyword.get(opts, :continuation_delay_ms),
            @default_continuation_delay_ms
          )
      }

      state =
        if state.auto_poll do
          schedule_poll(state, 0)
        else
          state
        end

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    state = run_poll_cycle(state)

    state =
      if state.auto_poll do
        schedule_poll(state, state.poll_interval_ms)
      else
        state
      end

    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, status_snapshot(state), state}
  end

  def handle_call({:stop_issue, issue_id}, _from, state) do
    state = stop_issue_now(state, issue_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_timer_ref: nil}
    state = run_poll_cycle(state)
    state = schedule_poll(state, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:retry_due, issue_id}, state) do
    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        {:noreply, state}

      {retry_entry, retry_attempts} ->
        state = %{state | retry_attempts: retry_attempts}
        {:noreply, dispatch_retry(state, issue_id, retry_entry)}
    end
  end

  def handle_info({:runner_event, issue_id, event}, state) do
    {:noreply, track_runner_event(state, issue_id, event)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case pop_running_by_ref(state, ref) do
      {:ok, issue_id, run_entry, state} ->
        {:noreply, handle_runner_result(state, issue_id, run_entry, result)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) when is_reference(ref) do
    case pop_running_by_ref(state, ref) do
      {:ok, issue_id, run_entry, state} ->
        next_attempt = next_retry_attempt(run_entry.attempt)

        reason =
          "Runner task exited before returning a result: #{inspect(reason)}"

        maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})

        state = tracker_mark_failed(state, issue_id, reason, next_attempt)

        state = maybe_schedule_retry(state, issue_id, run_entry.issue, next_attempt, reason)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # --- Poll cycle ---

  defp run_poll_cycle(state) do
    sync_repo(state.repo_local_path, state.repo_default_branch)

    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         {:ok, issues} <- list_active_issues(tracker, config) do
      state
      |> apply_runtime_limits(config)
      |> Map.put(:last_poll_at, DateTime.utc_now())
      |> clear_completed_for_open_issues(issues)
      |> reconcile_running(issues, config)
      |> prune_ineligible_retries(issues, config)
      |> dispatch_available(issues, config, tracker)
      |> Map.put(:last_error, nil)
    else
      {:error, reason} ->
        Logger.error("Orchestrator poll failed: #{reason}")
        %{state | last_error: reason, last_poll_at: DateTime.utc_now()}
    end
  end

  defp dispatch_retry(state, issue_id, retry_entry) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         {:ok, issues} <- list_active_issues(tracker, config) do
      state = apply_runtime_limits(state, config)
      issue = find_issue(issues, issue_id)

      if not is_nil(state.max_attempts) and retry_entry.attempt >= state.max_attempts do
        Logger.warning(
          "Max attempts (#{state.max_attempts}) reached for issue_id=#{issue_id} on retry dispatch; stopping"
        )

        state
        |> release_claim(issue_id)
        |> Map.update!(:completed, &MapSet.put(&1, issue_id))
      else
        cond do
          is_nil(issue) ->
            release_claim(state, issue_id)

          not issue_dispatchable?(issue, config) ->
            release_claim(state, issue_id)

          map_size(state.running) >= state.max_concurrent_agents ->
            schedule_retry(
              state,
              issue_id,
              issue,
              retry_entry.attempt,
              "no available orchestrator slots",
              retry_backoff_delay_ms(state, retry_entry.attempt)
            )

          true ->
            start_issue_run(state, issue, retry_entry.attempt, config, tracker)
        end
      end
    else
      {:error, reason} ->
        schedule_retry(
          state,
          issue_id,
          retry_entry.issue,
          retry_entry.attempt,
          "retry dispatch failed: #{reason}",
          retry_backoff_delay_ms(state, retry_entry.attempt)
        )
    end
  end

  # --- Dispatch and reconciliation ---

  defp clear_completed_for_open_issues(state, issues) do
    open_ids =
      issues
      |> Enum.filter(fn issue -> normalize_state(field(issue, :state)) == "open" end)
      |> Enum.map(&issue_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    %{state | completed: MapSet.difference(state.completed, open_ids)}
  end

  defp reconcile_running(state, issues, config) do
    active_ids =
      issues
      |> Enum.map(&issue_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reduce(state.running, state, fn {issue_id, run_entry}, acc ->
      if MapSet.member?(active_ids, issue_id) do
        acc
      else
        Logger.info("Stopping ineligible run issue_id=#{issue_id}")

        maybe_complete_run_logs(run_entry, %{status: :stopped, error: "issue is no longer active"})

        acc
        |> stop_run_task(run_entry)
        |> drop_running(issue_id, run_entry.task_ref)
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
        |> maybe_cleanup_terminal_workspace(run_entry, config)
      end
    end)
  end

  defp prune_ineligible_retries(state, issues, _config) do
    active_ids =
      issues
      |> Enum.map(&issue_id/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.reduce(Map.keys(state.retry_attempts), state, fn issue_id, acc ->
      if MapSet.member?(active_ids, issue_id) do
        acc
      else
        acc
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
      end
    end)
  end

  defp dispatch_available(state, issues, config, tracker) do
    available_slots = max(state.max_concurrent_agents - map_size(state.running), 0)

    if available_slots == 0 do
      state
    else
      issues
      |> Enum.filter(&eligible_for_new_dispatch?(&1, state, config))
      |> sort_issues_for_dispatch()
      |> Enum.take(available_slots)
      |> Enum.reduce(state, fn issue, acc ->
        start_issue_run(acc, issue, nil, config, tracker)
      end)
    end
  end

  defp start_issue_run(state, issue, attempt, config, tracker) do
    issue_id = issue_id(issue)
    identifier = issue_identifier(issue)

    with :ok <- tracker_prepare_issue_for_run(tracker, config, issue_id) do
      orchestrator_pid = self()
      {user_on_event, runner_opts} = Keyword.pop(state.runner_opts, :on_event)
      run_log_context = prepare_run_log_context(config, issue, attempt)

      session_opts = if field(issue, :resumable), do: %{resumable: true}, else: %{}

      run_opts =
        [
          workflow_store: state.workflow_store,
          attempt: attempt,
          session_opts: session_opts,
          on_event: runner_on_event(orchestrator_pid, issue_id, run_log_context, user_on_event)
        ] ++ runner_opts

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          invoke_runner(state.runner, issue, run_opts)
        end)

      runtime_profile = runtime_profile(config)

      run_entry = %{
        issue: issue,
        attempt: attempt,
        task_ref: task.ref,
        task_pid: task.pid,
        started_at: DateTime.utc_now(),
        runtime_profile: runtime_profile,
        runtime_process_state: initial_runtime_process_state(runtime_profile),
        runtime_last_event: nil,
        run_log_context: run_log_context
      }

      Logger.info(
        "Dispatching issue_id=#{issue_id} identifier=#{identifier} attempt=#{inspect(attempt)}"
      )

      state
      |> cancel_retry(issue_id)
      |> put_running(issue_id, run_entry)
      |> claim(issue_id)
    else
      {:error, reason} ->
        retry_attempt = retry_attempt_from_run_attempt(attempt)

        schedule_retry(
          state,
          issue_id,
          issue,
          retry_attempt,
          "tracker update failed before dispatch: #{reason}",
          retry_backoff_delay_ms(state, retry_attempt)
        )
    end
  end

  defp eligible_for_new_dispatch?(issue, state, config) do
    issue_id = issue_id(issue)
    issue_state = field(issue, :state)

    issue_dispatchable?(issue, config) and
      not is_nil(issue_id) and
      normalize_state(issue_state) != "in_progress" and
      not Map.has_key?(state.running, issue_id) and
      not MapSet.member?(state.claimed, issue_id) and
      not MapSet.member?(state.completed, issue_id)
  end

  defp issue_dispatchable?(issue, config) do
    issue_id = issue_id(issue)
    identifier = issue_identifier(issue)
    title = field(issue, :title)
    state_name = field(issue, :state)

    non_empty_string?(issue_id) and
      non_empty_string?(identifier) and
      non_empty_string?(title) and
      active_state?(state_name, config) and
      not terminal_state?(state_name, config) and
      not blocked_issue?(issue, config)
  end

  defp blocked_issue?(issue, config) do
    issue
    |> field(:blocked_by)
    |> list_value()
    |> Enum.any?(fn blocker ->
      blocker_state = field(blocker, :state)
      not success_terminal_state?(blocker_state, config)
    end)
  end

  defp success_terminal_state?(state_name, config) do
    terminal_state?(state_name, config) and normalize_state(state_name) == "done"
  end

  defp sort_issues_for_dispatch(issues) do
    Enum.sort_by(issues, fn issue ->
      {
        sort_priority(field(issue, :priority)),
        sort_created_at(field(issue, :created_at)),
        issue_identifier(issue) || ""
      }
    end)
  end

  # --- Runner result handling ---

  defp handle_runner_result(state, issue_id, run_entry, {:ok, %Result{} = result}) do
    maybe_complete_run_logs(run_entry, result)
    state = %{state | completed: MapSet.put(state.completed, issue_id)}

    case result.status do
      :ok ->
        case tracker_mark_done(state, issue_id, result, run_entry) do
          {:ok, state} ->
            state

          {:error, reason, state} ->
            next_attempt = next_retry_attempt(run_entry.attempt)

            maybe_schedule_retry(
              state,
              issue_id,
              run_entry.issue,
              next_attempt,
              "failed to mark issue done: #{reason}"
            )
        end

      :max_turns_reached ->
        next_attempt = next_retry_attempt(run_entry.attempt)

        case tracker_mark_resumable(state, issue_id, result, run_entry) do
          {:ok, state} ->
            schedule_retry(
              state,
              issue_id,
              run_entry.issue,
              next_attempt,
              nil,
              state.continuation_delay_ms
            )

          {:error, reason, state} ->
            maybe_schedule_retry(
              state,
              issue_id,
              run_entry.issue,
              next_attempt,
              "failed to mark issue resumable: #{reason}"
            )
        end

      _other ->
        next_attempt = next_retry_attempt(run_entry.attempt)
        reason = "runner returned non-success status: #{inspect(result.status)}"
        state = tracker_mark_failed(state, issue_id, reason, next_attempt)

        maybe_schedule_retry(state, issue_id, run_entry.issue, next_attempt, reason)
    end
  end

  defp handle_runner_result(state, issue_id, run_entry, {:error, %Result{} = result}) do
    maybe_complete_run_logs(run_entry, result)
    next_attempt = next_retry_attempt(run_entry.attempt)
    reason = result.error || "runner returned error"
    state = tracker_mark_failed(state, issue_id, reason, next_attempt)

    maybe_schedule_retry(state, issue_id, run_entry.issue, next_attempt, reason)
  end

  defp handle_runner_result(state, issue_id, run_entry, other_result) do
    reason = "runner returned unexpected result: #{inspect(other_result)}"

    maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})

    next_attempt = next_retry_attempt(run_entry.attempt)
    state = tracker_mark_failed(state, issue_id, reason, next_attempt)

    maybe_schedule_retry(state, issue_id, run_entry.issue, next_attempt, reason)
  end

  # --- Retry and claim management ---

  defp maybe_schedule_retry(state, issue_id, issue, attempt, reason) do
    cond do
      not is_nil(state.max_attempts) and attempt >= state.max_attempts ->
        Logger.warning(
          "Max attempts (#{state.max_attempts}) reached for issue_id=#{issue_id}; stopping: #{reason}"
        )

        state
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
        |> Map.update!(:completed, &MapSet.put(&1, issue_id))

      state.retries_enabled ->
        schedule_retry(
          state,
          issue_id,
          issue,
          attempt,
          reason,
          retry_backoff_delay_ms(state, attempt)
        )

      true ->
        Logger.warning(
          "Retries disabled for issue_id=#{issue_id}; stopping retries after failure: #{reason}"
        )

        state
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
        |> Map.update!(:completed, &MapSet.put(&1, issue_id))
    end
  end

  defp schedule_retry(state, issue_id, issue, attempt, reason, delay_ms) do
    if state.retries_enabled do
      state = cancel_retry(state, issue_id)
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms
      timer_ref = Process.send_after(self(), {:retry_due, issue_id}, delay_ms)

      if reason do
        Logger.warning(
          "Scheduling retry issue_id=#{issue_id} attempt=#{attempt} delay_ms=#{delay_ms} reason=#{reason}"
        )
      else
        Logger.info("Scheduling continuation issue_id=#{issue_id} delay_ms=#{delay_ms}")
      end

      retry_entry = %{
        issue: issue,
        attempt: attempt,
        reason: reason,
        timer_ref: timer_ref,
        due_at_ms: due_at_ms
      }

      %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry)}
      |> claim(issue_id)
    else
      Logger.warning(
        "Retries disabled for issue_id=#{issue_id}; not scheduling retry#{if reason, do: " reason=#{reason}", else: ""}"
      )

      state
      |> cancel_retry(issue_id)
      |> release_claim(issue_id)
    end
  end

  defp retry_backoff_delay_ms(state, attempt) do
    max_backoff = state.max_retry_backoff_ms
    base_delay = state.retry_base_delay_ms
    exponent = max(attempt - 1, 0)

    base_delay
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(max_backoff)
  end

  defp next_retry_attempt(nil), do: 1
  defp next_retry_attempt(attempt) when is_integer(attempt) and attempt >= 1, do: attempt + 1
  defp next_retry_attempt(_), do: 1

  defp retry_attempt_from_run_attempt(nil), do: 1

  defp retry_attempt_from_run_attempt(attempt) when is_integer(attempt) and attempt >= 1,
    do: attempt

  defp retry_attempt_from_run_attempt(_), do: 1

  defp claim(state, issue_id), do: %{state | claimed: MapSet.put(state.claimed, issue_id)}

  defp release_claim(state, issue_id),
    do: %{state | claimed: MapSet.delete(state.claimed, issue_id)}

  defp cancel_retry(state, issue_id) do
    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        state

      {retry_entry, retry_attempts} ->
        Process.cancel_timer(retry_entry.timer_ref)
        %{state | retry_attempts: retry_attempts}
    end
  end

  # --- Running tasks ---

  defp put_running(state, issue_id, run_entry) do
    %{
      state
      | running: Map.put(state.running, issue_id, run_entry),
        running_by_ref: Map.put(state.running_by_ref, run_entry.task_ref, issue_id)
    }
  end

  defp drop_running(state, issue_id, task_ref) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        running_by_ref: Map.delete(state.running_by_ref, task_ref)
    }
  end

  defp pop_running_by_ref(state, task_ref) do
    case Map.pop(state.running_by_ref, task_ref) do
      {nil, _running_by_ref} ->
        :error

      {issue_id, running_by_ref} ->
        case Map.pop(state.running, issue_id) do
          {nil, _running} ->
            :error

          {run_entry, running} ->
            {:ok, issue_id, run_entry,
             %{state | running: running, running_by_ref: running_by_ref}}
        end
    end
  end

  defp stop_run_task(state, run_entry) do
    Process.exit(run_entry.task_pid, :kill)
    state
  rescue
    _ -> state
  end

  defp stop_issue_now(state, issue_id) do
    state = cancel_retry(state, issue_id)

    case Map.get(state.running, issue_id) do
      nil ->
        release_claim(state, issue_id)

      run_entry ->
        maybe_complete_run_logs(run_entry, %{status: :stopped, error: "run stopped by operator"})

        state
        |> stop_run_task(run_entry)
        |> drop_running(issue_id, run_entry.task_ref)
        |> release_claim(issue_id)
    end
  end

  defp track_runner_event(state, issue_id, event) do
    if not is_map(event) do
      state
    else
      case Map.get(state.running, issue_id) do
        nil ->
          state

        run_entry ->
          {runtime_process_state, runtime_last_event} =
            runtime_state_from_event(run_entry, event)

          updated_entry =
            run_entry
            |> Map.put(:runtime_process_state, runtime_process_state)
            |> Map.put(:runtime_last_event, runtime_last_event)

          put_running(state, issue_id, updated_entry)
      end
    end
  end

  defp runtime_state_from_event(run_entry, event) do
    event_type = Map.get(event, :type) || Map.get(event, "type")
    timestamp = Map.get(event, :timestamp) || Map.get(event, "timestamp")

    runtime_process_state =
      case event_type do
        :runtime_starting -> :starting
        :runtime_started -> :running
        :runtime_start_failed -> :start_failed
        :runtime_stopping -> :stopping
        :runtime_stopped -> :stopped
        :runtime_stop_failed -> :stop_failed
        "runtime_starting" -> :starting
        "runtime_started" -> :running
        "runtime_start_failed" -> :start_failed
        "runtime_stopping" -> :stopping
        "runtime_stopped" -> :stopped
        "runtime_stop_failed" -> :stop_failed
        _other -> Map.get(run_entry, :runtime_process_state, :unknown)
      end

    runtime_last_event =
      if runtime_event_type?(event_type) do
        %{
          type: event_type,
          timestamp: timestamp
        }
      else
        Map.get(run_entry, :runtime_last_event)
      end

    {runtime_process_state, runtime_last_event}
  end

  defp runtime_event_type?(event_type) do
    event_type in [
      :runtime_starting,
      :runtime_started,
      :runtime_start_failed,
      :runtime_stopping,
      :runtime_stopped,
      :runtime_stop_failed,
      "runtime_starting",
      "runtime_started",
      "runtime_start_failed",
      "runtime_stopping",
      "runtime_stopped",
      "runtime_stop_failed"
    ]
  end

  # --- Config and integration ---

  defp sync_repo(nil, _branch), do: :ok

  defp sync_repo(local_path, branch) do
    with {_, 0} <-
           System.cmd("git", ["fetch", "--all", "--prune"],
             cd: local_path,
             stderr_to_stdout: true
           ),
         {_, 0} <-
           System.cmd("git", ["reset", "--hard", "origin/#{branch}"],
             cd: local_path,
             stderr_to_stdout: true
           ) do
      :ok
    else
      {output, code} ->
        Logger.warning("Repo sync failed (exit #{code}): #{String.trim(output)}")
        :ok
    end
  end

  defp fetch_config(%Config{} = config), do: {:ok, config}

  defp fetch_config(workflow_store) do
    case WorkflowStore.get_config(workflow_store) do
      %Config{} = config ->
        {:ok, config}

      nil ->
        {:error, "workflow config is unavailable"}

      other ->
        {:error, "workflow config is invalid: #{inspect(other)}"}
    end
  end

  defp resolve_tracker(:auto, config) do
    kind = get_in(config, [Access.key(:tracker, %{}), Access.key(:kind)])
    Tracker.module_for_kind(kind)
  end

  defp resolve_tracker(tracker, _config), do: tracker

  defp tracker_prepare_issue_for_run(tracker, config, issue_id) do
    with :ok <- tracker_call(tracker, :claim_issue, [config, issue_id]),
         :ok <- tracker_call(tracker, :mark_in_progress, [config, issue_id]) do
      :ok
    end
  end

  defp tracker_mark_done(state, issue_id, %Result{} = result, run_entry) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <-
           tracker_call(tracker, :mark_done, [
             config,
             issue_id,
             tracker_done_metadata(result, run_entry)
           ]) do
      state = release_claim(state, issue_id)
      {:ok, maybe_cleanup_terminal_workspace(state, run_entry, config)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp tracker_mark_failed(state, issue_id, reason, attempt) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <- tracker_call(tracker, :mark_failed, [config, issue_id, reason, attempt]) do
      state
    else
      {:error, tracker_reason} ->
        Logger.warning(
          "Failed to mark issue failed issue_id=#{issue_id} attempt=#{attempt}: #{tracker_reason}"
        )

        state
    end
  end

  defp tracker_mark_resumable(state, issue_id, %Result{} = result, run_entry) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <-
           tracker_call(tracker, :mark_resumable, [
             config,
             issue_id,
             tracker_done_metadata(result, run_entry)
           ]) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp tracker_call(tracker, _function_name, _args) when is_function(tracker, 1), do: :ok

  defp tracker_call(tracker, function_name, args) when is_atom(tracker) do
    arity = length(args)

    if function_exported?(tracker, function_name, arity) do
      response = apply(tracker, function_name, args)
      normalize_tracker_action_response(response, tracker, function_name, arity)
    else
      :ok
    end
  rescue
    error ->
      arity = length(args)

      {:error,
       "tracker module #{inspect(tracker)} failed in #{function_name}/#{arity}: #{Exception.message(error)}"}
  end

  defp tracker_call(tracker, _function_name, _args) do
    {:error, "invalid tracker adapter: #{inspect(tracker)}"}
  end

  defp normalize_tracker_action_response(:ok, _tracker, _function_name, _arity), do: :ok

  defp normalize_tracker_action_response({:error, reason}, _tracker, _function_name, _arity),
    do: {:error, to_string(reason)}

  defp normalize_tracker_action_response(response, tracker, function_name, arity) do
    {:error,
     "tracker module #{inspect(tracker)} returned #{inspect(response)} for #{function_name}/#{arity}"}
  end

  defp tracker_done_metadata(%Result{} = result, run_entry) do
    base = %{
      status: result.status,
      turn_count: result.turn_count,
      ended_at: result.ended_at,
      workspace_path: result.workspace_path
    }

    run_log_metadata =
      run_entry
      |> Map.get(:run_log_context)
      |> case do
        nil -> %{}
        context -> RunLogs.tracker_metadata(context)
      end

    Map.merge(base, run_log_metadata)
  end

  defp list_active_issues(tracker, config) when is_function(tracker, 1) do
    normalize_issue_response(tracker.(config))
  rescue
    error -> {:error, "tracker function failed: #{Exception.message(error)}"}
  end

  defp list_active_issues(tracker, config) when is_atom(tracker) do
    normalize_issue_response(tracker.list_active_issues(config))
  rescue
    UndefinedFunctionError ->
      {:error, "tracker module #{inspect(tracker)} must implement list_active_issues/1"}

    error ->
      {:error, "tracker module #{inspect(tracker)} failed: #{Exception.message(error)}"}
  end

  defp normalize_issue_response({:ok, issues}) when is_list(issues), do: {:ok, issues}
  defp normalize_issue_response({:error, reason}), do: {:error, to_string(reason)}

  defp normalize_issue_response(other) do
    {:error, "tracker must return {:ok, issues} or {:error, reason}, got: #{inspect(other)}"}
  end

  defp invoke_runner(runner, issue, run_opts) when is_function(runner, 2) do
    runner.(issue, run_opts)
  rescue
    error ->
      {:error,
       %Result{
         status: :failed,
         started_at: now(),
         ended_at: now(),
         error: Exception.message(error)
       }}
  end

  defp invoke_runner(runner, issue, run_opts) when is_atom(runner) do
    runner.run_issue(issue, run_opts)
  rescue
    UndefinedFunctionError ->
      {:error,
       %Result{
         status: :failed,
         started_at: now(),
         ended_at: now(),
         error: "runner module #{inspect(runner)} must implement run_issue/2"
       }}

    error ->
      {:error,
       %Result{
         status: :failed,
         started_at: now(),
         ended_at: now(),
         error: Exception.message(error)
       }}
  end

  defp runner_on_event(orchestrator_pid, issue_id, run_log_context, user_on_event)
       when is_function(user_on_event, 1) do
    fn event ->
      send(orchestrator_pid, {:runner_event, issue_id, event})
      persist_run_log_event(run_log_context, event)
      user_on_event.(event)
    end
  end

  defp runner_on_event(orchestrator_pid, issue_id, run_log_context, nil) do
    fn event ->
      send(orchestrator_pid, {:runner_event, issue_id, event})
      persist_run_log_event(run_log_context, event)
      :ok
    end
  end

  defp runner_on_event(orchestrator_pid, issue_id, run_log_context, _other) do
    fn event ->
      send(orchestrator_pid, {:runner_event, issue_id, event})
      persist_run_log_event(run_log_context, event)
      :ok
    end
  end

  defp prepare_run_log_context(config, issue, attempt) do
    case RunLogs.prepare_attempt(config, issue, attempt) do
      {:ok, context} ->
        context

      {:error, reason} ->
        Logger.warning(
          "Failed to initialize run logs issue_id=#{issue_id(issue) || "-"} identifier=#{issue_identifier(issue) || "-"}: #{reason}"
        )

        nil
    end
  end

  defp persist_run_log_event(nil, _event), do: :ok

  defp persist_run_log_event(run_log_context, event) do
    case RunLogs.append_event(run_log_context, event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to append run log event issue_id=#{run_log_context[:issue_id] || "-"} attempt=#{run_log_context[:attempt] || "-"}: #{reason}"
        )

        :ok
    end
  end

  defp maybe_complete_run_logs(run_entry, completion) when is_map(run_entry) do
    case Map.get(run_entry, :run_log_context) do
      nil ->
        :ok

      run_log_context ->
        case RunLogs.complete_attempt(run_log_context, completion) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to finalize run logs issue_id=#{issue_id(run_entry.issue) || "-"} attempt=#{run_log_context[:attempt] || "-"}: #{reason}"
            )

            :ok
        end
    end
  end

  defp maybe_complete_run_logs(_run_entry, _completion), do: :ok

  defp runtime_profile(config) do
    case get_in(config, [Access.key(:runtime, %{}), Access.key(:profile)]) do
      :full_stack -> :full_stack
      "full_stack" -> :full_stack
      _other -> :checks_only
    end
  end

  defp initial_runtime_process_state(:full_stack), do: :pending
  defp initial_runtime_process_state(_profile), do: :not_required

  defp apply_runtime_limits(state, config) do
    poll_interval_ms =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:interval_ms)]),
        state.poll_interval_ms
      )

    max_concurrent_agents =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:max_concurrent_agents)]),
        state.max_concurrent_agents
      )

    max_retry_backoff_ms =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:max_retry_backoff_ms)]),
        state.max_retry_backoff_ms
      )

    retries_enabled =
      config
      |> get_in([Access.key(:agent, %{}), Access.key(:retries_enabled)])
      |> case do
        value when is_boolean(value) -> value
        value when is_binary(value) -> String.downcase(String.trim(value)) in ["true", "1", "yes"]
        _other -> state.retries_enabled
      end

    max_attempts =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:max_attempts)]),
        state.max_attempts
      )

    %{
      state
      | poll_interval_ms: poll_interval_ms,
        max_concurrent_agents: max_concurrent_agents,
        max_retry_backoff_ms: max_retry_backoff_ms,
        retries_enabled: retries_enabled,
        max_attempts: max_attempts
    }
  end

  defp active_state?(state_name, config) do
    normalized = normalize_state(state_name)

    config
    |> get_in([Access.key(:tracker, %{}), Access.key(:active_states, [])])
    |> Enum.map(&normalize_state/1)
    |> Enum.member?(normalized)
  end

  defp terminal_state?(state_name, config) do
    normalized = normalize_state(state_name)

    config
    |> get_in([Access.key(:tracker, %{}), Access.key(:terminal_states, [])])
    |> Enum.map(&normalize_state/1)
    |> Enum.member?(normalized)
  end

  defp normalize_state(nil), do: ""

  defp normalize_state(state_name),
    do: state_name |> to_string() |> String.trim() |> String.downcase()

  defp issue_id(issue) do
    value = field(issue, :id)
    if non_empty_string?(value), do: value, else: nil
  end

  defp issue_identifier(issue) do
    value = field(issue, :identifier)
    if non_empty_string?(value), do: value, else: nil
  end

  defp find_issue(issues, issue_id) do
    Enum.find(issues, fn issue -> issue_id(issue) == issue_id end)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp sort_priority(nil), do: 99
  defp sort_priority(value) when is_integer(value), do: value

  defp sort_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 99
    end
  end

  defp sort_priority(_value), do: 99

  defp sort_created_at(nil), do: 9_223_372_036_854_775_807

  defp sort_created_at(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :millisecond)

  defp sort_created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :millisecond)
      _ -> 9_223_372_036_854_775_807
    end
  end

  defp sort_created_at(_value), do: 9_223_372_036_854_775_807

  defp positive_integer(value, _fallback) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> fallback
    end
  end

  defp positive_integer(_value, fallback), do: fallback

  defp schedule_poll(state, delay_ms) do
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    ref = Process.send_after(self(), :poll, delay_ms)
    %{state | poll_timer_ref: ref}
  end

  defp status_snapshot(state) do
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, entry} ->
        runtime_last_event = Map.get(entry, :runtime_last_event)

        %{
          issue_id: issue_id,
          identifier: issue_identifier(entry.issue),
          attempt: entry.attempt,
          started_at: entry.started_at,
          runtime_profile: Map.get(entry, :runtime_profile, :checks_only),
          runtime_process_state: Map.get(entry, :runtime_process_state, :unknown),
          runtime_last_event_type: runtime_last_event_type(runtime_last_event),
          runtime_last_event_at: runtime_last_event_at(runtime_last_event)
        }
      end)
      |> Enum.sort_by(& &1.issue_id)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, entry} ->
        %{
          issue_id: issue_id,
          identifier: issue_identifier(entry.issue),
          attempt: entry.attempt,
          reason: entry.reason,
          due_in_ms: max(entry.due_at_ms - now_ms, 0)
        }
      end)
      |> Enum.sort_by(& &1.issue_id)

    %{
      running: running,
      retrying: retrying,
      running_count: map_size(state.running),
      retry_count: map_size(state.retry_attempts),
      claimed_count: MapSet.size(state.claimed),
      claimed_issue_ids: state.claimed |> MapSet.to_list() |> Enum.sort(),
      completed_count: MapSet.size(state.completed),
      completed_issue_ids: state.completed |> MapSet.to_list() |> Enum.sort(),
      poll_interval_ms: state.poll_interval_ms,
      max_concurrent_agents: state.max_concurrent_agents,
      retries_enabled: state.retries_enabled,
      max_attempts: state.max_attempts,
      max_retry_backoff_ms: state.max_retry_backoff_ms,
      retry_base_delay_ms: state.retry_base_delay_ms,
      continuation_delay_ms: state.continuation_delay_ms,
      last_error: state.last_error,
      last_poll_at: state.last_poll_at
    }
  end

  defp runtime_last_event_type(%{} = event), do: Map.get(event, :type)
  defp runtime_last_event_type(_event), do: nil

  defp runtime_last_event_at(%{} = event), do: Map.get(event, :timestamp)
  defp runtime_last_event_at(_event), do: nil

  defp maybe_cleanup_terminal_workspace(state, _run_entry, _config), do: state

  defp now, do: DateTime.utc_now()
end
