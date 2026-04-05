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

  alias Kollywood.AgentPool
  alias Kollywood.AgentRunner
  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator.ControlState
  alias Kollywood.Orchestrator.EphemeralStore
  alias Kollywood.Orchestrator.RunPhase
  alias Kollywood.Orchestrator.RetryStore
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Orchestrator.RunSettingsSnapshot
  alias Kollywood.Publisher
  alias Kollywood.RecoveryGuidance
  alias Kollywood.RepoSync
  alias Kollywood.StoryExecutionOverrides
  alias Kollywood.RunQueue
  alias Kollywood.Tracker
  alias Kollywood.Workspace
  alias Kollywood.WorkflowStore

  @default_poll_interval_ms 5_000
  @default_repo_sync_interval_ms 30_000
  @default_repo_sync_timeout_ms 15_000
  @default_claim_ttl_ms 86_400_000
  @default_completed_ttl_ms 60_000
  @default_max_concurrent_agents 1
  @default_global_max_concurrent_agents 5
  @default_max_retry_backoff_ms 300_000
  @default_retry_base_delay_ms 10_000
  @default_continuation_delay_ms 1_000
  @default_stale_threshold_multiplier 3
  @default_status_tick_interval_ms 1_000
  @maintenance_retry_defer_ms 5_000

  @type state :: %__MODULE__{
          workflow_store: WorkflowStore.server() | Config.t(),
          tracker: :auto | module() | (Config.t() -> {:ok, [map()]} | {:error, String.t()}),
          runner: module() | (map(), keyword() -> {:ok, Result.t()} | {:error, Result.t()}),
          agent_pool: GenServer.server(),
          ephemeral_store: module() | nil,
          retry_store: module() | nil,
          merge_checker:
            (Config.t(), String.t() -> {:ok, boolean()} | {:error, String.t()}) | nil,
          runner_opts: keyword(),
          auto_poll: boolean(),
          poll_timer_ref: reference() | nil,
          watchdog_timer_ref: reference() | nil,
          status_tick_timer_ref: reference() | nil,
          maintenance_mode: :normal | :drain,
          poll_interval_ms: pos_integer(),
          stale_threshold_multiplier: pos_integer(),
          watchdog_check_interval_ms: pos_integer(),
          repo_sync_interval_ms: pos_integer(),
          repo_sync_timeout_ms: pos_integer(),
          last_repo_sync_at_ms: integer() | nil,
          repo_sync_task_ref: reference() | nil,
          repo_sync_task_pid: pid() | nil,
          repo_sync_timeout_timer_ref: reference() | nil,
          repo_sync_started_at_ms: integer() | nil,
          requested_max_concurrent_agents: pos_integer(),
          global_max_concurrent_agents: pos_integer(),
          max_concurrent_agents: pos_integer(),
          max_retry_backoff_ms: pos_integer(),
          retries_enabled: boolean(),
          max_attempts: pos_integer() | nil,
          retry_base_delay_ms: pos_integer(),
          continuation_delay_ms: pos_integer(),
          claim_ttl_ms: pos_integer(),
          completed_ttl_ms: pos_integer(),
          run_timeout_ms: pos_integer() | nil,
          project_limit_fetcher: (-> map() | list()) | module() | nil,
          project_max_concurrent_agents: %{optional(String.t()) => pos_integer()},
          dispatch_rotation: non_neg_integer(),
          running: %{optional(String.t()) => map()},
          running_by_ref: %{optional(reference()) => String.t()},
          claimed: MapSet.t(String.t()),
          claimed_until: %{optional(String.t()) => integer()},
          retry_attempts: %{optional(String.t()) => map()},
          completed: MapSet.t(String.t()),
          completed_until: %{optional(String.t()) => integer()},
          dispatch_mode: :local | :queue,
          queue_poll_timer_ref: reference() | nil,
          last_error: String.t() | nil,
          last_poll_at: DateTime.t() | nil,
          last_poll_monotonic_ms: integer() | nil,
          poll_stale: boolean(),
          poll_stale_detected_at: DateTime.t() | nil,
          poll_stale_recovery_attempted: boolean(),
          last_recovery_attempt: map() | nil
        }

  defstruct [
    :workflow_store,
    :tracker,
    :runner,
    :agent_pool,
    :ephemeral_store,
    :retry_store,
    :merge_checker,
    :runner_opts,
    :auto_poll,
    :poll_timer_ref,
    :watchdog_timer_ref,
    :status_tick_timer_ref,
    :maintenance_mode,
    :poll_interval_ms,
    :stale_threshold_multiplier,
    :watchdog_check_interval_ms,
    :repo_sync_interval_ms,
    :repo_sync_timeout_ms,
    :last_repo_sync_at_ms,
    :repo_sync_task_ref,
    :repo_sync_task_pid,
    :repo_sync_timeout_timer_ref,
    :repo_sync_started_at_ms,
    :requested_max_concurrent_agents,
    :global_max_concurrent_agents,
    :max_concurrent_agents,
    :max_retry_backoff_ms,
    :retries_enabled,
    :max_attempts,
    :retry_base_delay_ms,
    :continuation_delay_ms,
    :claim_ttl_ms,
    :completed_ttl_ms,
    :run_timeout_ms,
    :project_limit_fetcher,
    :project_max_concurrent_agents,
    :repo_syncer,
    :repo_local_path,
    :repo_default_branch,
    :last_error,
    :last_poll_at,
    :last_poll_monotonic_ms,
    :poll_stale,
    :poll_stale_detected_at,
    :poll_stale_recovery_attempted,
    :last_recovery_attempt,
    dispatch_mode: :local,
    queue_poll_timer_ref: nil,
    dispatch_rotation: 0,
    running: %{},
    running_by_ref: %{},
    claimed: MapSet.new(),
    claimed_until: %{},
    retry_attempts: %{},
    completed: MapSet.new(),
    completed_until: %{}
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

  @doc "Sets orchestrator maintenance mode (`:normal` or `:drain`)."
  @spec set_maintenance_mode(server(), :normal | :drain | String.t()) ::
          :ok | {:error, :invalid_mode}
  def set_maintenance_mode(server \\ __MODULE__, mode) do
    GenServer.call(server, {:set_maintenance_mode, mode})
  end

  @impl true
  def init(opts) do
    with {:ok, agent_pool} <- resolve_agent_pool(Keyword.get(opts, :agent_pool, AgentPool)) do
      maintenance_mode = ControlState.load_maintenance_mode(:normal)

      poll_interval_ms =
        positive_integer(Keyword.get(opts, :poll_interval_ms), @default_poll_interval_ms)

      watchdog_check_interval_ms =
        positive_integer(Keyword.get(opts, :watchdog_check_interval_ms), poll_interval_ms)

      requested_max_concurrent_agents =
        positive_integer(
          Keyword.get(opts, :max_concurrent_agents),
          @default_max_concurrent_agents
        )

      global_max_concurrent_agents =
        positive_integer_with_default(
          Keyword.get(opts, :global_max_concurrent_agents),
          @default_global_max_concurrent_agents,
          "orchestrator.global_max_concurrent_agents"
        )

      effective_max_concurrent_agents =
        clamp_max_concurrent_agents(requested_max_concurrent_agents, global_max_concurrent_agents)

      state = %__MODULE__{
        workflow_store: Keyword.get(opts, :workflow_store, WorkflowStore),
        tracker: Keyword.get(opts, :tracker, :auto),
        runner: Keyword.get(opts, :runner, AgentRunner),
        agent_pool: agent_pool,
        ephemeral_store:
          resolve_ephemeral_store(Keyword.get(opts, :ephemeral_store, :__default__)),
        retry_store: resolve_retry_store(Keyword.get(opts, :retry_store, :__default__)),
        merge_checker: Keyword.get(opts, :merge_checker),
        runner_opts: Keyword.get(opts, :runner_opts, []),
        auto_poll: Keyword.get(opts, :auto_poll, true),
        poll_timer_ref: nil,
        watchdog_timer_ref: nil,
        status_tick_timer_ref: nil,
        maintenance_mode: maintenance_mode,
        poll_interval_ms: poll_interval_ms,
        stale_threshold_multiplier:
          positive_integer(
            Keyword.get(opts, :stale_threshold_multiplier),
            @default_stale_threshold_multiplier
          ),
        watchdog_check_interval_ms: watchdog_check_interval_ms,
        repo_sync_interval_ms:
          positive_integer(
            Keyword.get(opts, :repo_sync_interval_ms),
            @default_repo_sync_interval_ms
          ),
        repo_sync_timeout_ms:
          positive_integer(
            Keyword.get(opts, :repo_sync_timeout_ms),
            @default_repo_sync_timeout_ms
          ),
        last_repo_sync_at_ms: nil,
        repo_sync_task_ref: nil,
        repo_sync_task_pid: nil,
        repo_sync_timeout_timer_ref: nil,
        repo_sync_started_at_ms: nil,
        requested_max_concurrent_agents: requested_max_concurrent_agents,
        global_max_concurrent_agents: global_max_concurrent_agents,
        max_concurrent_agents: effective_max_concurrent_agents,
        max_retry_backoff_ms:
          positive_integer(
            Keyword.get(opts, :max_retry_backoff_ms),
            @default_max_retry_backoff_ms
          ),
        retries_enabled: Keyword.get(opts, :retries_enabled, false),
        max_attempts: positive_integer(Keyword.get(opts, :max_attempts), nil),
        repo_syncer: Keyword.get(opts, :repo_syncer),
        repo_local_path: Keyword.get(opts, :repo_local_path),
        repo_default_branch: Keyword.get(opts, :repo_default_branch, "main"),
        retry_base_delay_ms:
          positive_integer(Keyword.get(opts, :retry_base_delay_ms), @default_retry_base_delay_ms),
        continuation_delay_ms:
          positive_integer(
            Keyword.get(opts, :continuation_delay_ms),
            @default_continuation_delay_ms
          ),
        claim_ttl_ms: positive_integer(Keyword.get(opts, :claim_ttl_ms), @default_claim_ttl_ms),
        completed_ttl_ms:
          positive_integer(Keyword.get(opts, :completed_ttl_ms), @default_completed_ttl_ms),
        run_timeout_ms: positive_integer(Keyword.get(opts, :run_timeout_ms), nil),
        project_limit_fetcher:
          Keyword.get(opts, :project_limit_fetcher, &default_project_limit_fetcher/0),
        dispatch_mode: resolve_dispatch_mode(Keyword.get(opts, :dispatch_mode, :local)),
        queue_poll_timer_ref: nil,
        project_max_concurrent_agents: %{},
        dispatch_rotation: 0,
        last_poll_monotonic_ms: monotonic_now_ms(),
        poll_stale: false,
        poll_stale_detected_at: nil,
        poll_stale_recovery_attempted: false,
        last_recovery_attempt: nil
      }

      state =
        state
        |> cleanup_orphan_workers()
        |> restore_persisted_ephemeral_state()
        |> startup_reconcile()
        |> restore_persisted_retries()

      state =
        if state.auto_poll do
          state
          |> schedule_poll(0)
          |> schedule_watchdog_tick(0)
        else
          state
        end

      state =
        if state.dispatch_mode == :queue do
          RunQueue.subscribe()
          state
        else
          state
        end

      state =
        state
        |> schedule_status_tick(0)
        |> persist_control_status()

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:poll_now, _from, state) do
    state = refresh_maintenance_mode(state)
    state = run_poll_cycle(state)

    state =
      if state.auto_poll do
        state
        |> schedule_poll(state.poll_interval_ms)
        |> schedule_watchdog_tick(state.watchdog_check_interval_ms)
      else
        state
      end

    {:reply, :ok, persist_control_status(state)}
  end

  def handle_call(:status, _from, state) do
    state = refresh_maintenance_mode(state)
    snapshot = status_snapshot(state)
    {:reply, snapshot, persist_control_status(state)}
  end

  def handle_call({:stop_issue, issue_id}, _from, state) do
    state = stop_issue_now(state, issue_id)
    {:reply, :ok, persist_control_status(state)}
  end

  def handle_call({:set_maintenance_mode, mode}, _from, state) do
    case normalize_maintenance_mode(mode) do
      :invalid ->
        {:reply, {:error, :invalid_mode}, state}

      normalized_mode ->
        state =
          state
          |> set_maintenance_mode_state(normalized_mode, source: :api)
          |> persist_control_status()

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    state = %{state | poll_timer_ref: nil}
    state = refresh_maintenance_mode(state)
    state = run_poll_cycle(state)

    state =
      state
      |> schedule_poll(state.poll_interval_ms)
      |> schedule_watchdog_tick(state.watchdog_check_interval_ms)

    {:noreply, persist_control_status(state)}
  end

  def handle_info(:watchdog_tick, state) do
    state = %{state | watchdog_timer_ref: nil}
    state = refresh_maintenance_mode(state)
    state = run_poll_watchdog(state)

    state =
      if state.auto_poll do
        schedule_watchdog_tick(state, state.watchdog_check_interval_ms)
      else
        state
      end

    {:noreply, persist_control_status(state)}
  end

  def handle_info(:status_tick, state) do
    state = %{state | status_tick_timer_ref: nil}
    state = refresh_maintenance_mode(state)

    state =
      state
      |> schedule_status_tick(@default_status_tick_interval_ms)
      |> persist_control_status()

    {:noreply, state}
  end

  def handle_info({:retry_due, issue_id}, state) do
    state = refresh_maintenance_mode(state)

    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        {:noreply, persist_control_status(state)}

      {retry_entry, retry_attempts} ->
        state = %{state | retry_attempts: retry_attempts}
        state = delete_persisted_retry(state, issue_id)

        state =
          if state.maintenance_mode == :drain do
            defer_retry_due_to_maintenance(state, issue_id, retry_entry)
          else
            dispatch_retry(state, issue_id, retry_entry)
          end

        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:repo_sync_result, repo_sync_pid, result}, state)
      when is_pid(repo_sync_pid) do
    if repo_sync_pid == state.repo_sync_task_pid do
      state = clear_repo_sync_task_state(state)

      state =
        case result do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("Managed repo sync failed: #{reason}")

            Map.put(
              state,
              :last_error,
              RecoveryGuidance.repo_sync_failed(
                state.repo_local_path,
                state.repo_default_branch,
                to_string(reason)
              )
            )

          other ->
            Logger.warning("Managed repo sync returned unexpected result: #{inspect(other)}")

            Map.put(
              state,
              :last_error,
              RecoveryGuidance.repo_sync_failed(
                state.repo_local_path,
                state.repo_default_branch,
                "unexpected sync result: #{inspect(other)}"
              )
            )
        end

      {:noreply, persist_control_status(state)}
    else
      {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:repo_sync_timeout, ref, repo_sync_pid}, state)
      when is_reference(ref) and is_pid(repo_sync_pid) do
    if state.repo_sync_task_ref == ref and state.repo_sync_task_pid == repo_sync_pid do
      duration_ms =
        case state.repo_sync_started_at_ms do
          started_at_ms when is_integer(started_at_ms) ->
            max(System.monotonic_time(:millisecond) - started_at_ms, 0)

          _other ->
            state.repo_sync_timeout_ms
        end

      Logger.warning(
        "Managed repo sync timed out after #{duration_ms}ms (timeout=#{state.repo_sync_timeout_ms}ms)"
      )

      Process.exit(repo_sync_pid, :kill)

      state =
        state
        |> clear_repo_sync_task_state()
        |> Map.put(
          :last_error,
          RecoveryGuidance.repo_sync_timeout(
            state.repo_local_path,
            state.repo_default_branch,
            duration_ms,
            state.repo_sync_timeout_ms
          )
        )

      {:noreply, persist_control_status(state)}
    else
      {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:runner_event, issue_id, event}, state) do
    {:noreply, state |> track_runner_event(issue_id, event) |> persist_control_status()}
  end

  def handle_info({:run_queue, {:completed, _entry_id, issue_id, result_payload}}, state)
      when state.dispatch_mode == :queue do
    case Map.get(state.running, issue_id) do
      %{queue_entry_id: _entry_id} ->
        case pop_running_by_issue(state, issue_id) do
          {:ok, run_entry, state} ->
            cancel_run_timeout_timer(run_entry)
            result = reconstruct_result_from_payload(result_payload)

            {:noreply,
             state
             |> handle_runner_result(issue_id, run_entry, result)
             |> persist_control_status()}

          :error ->
            {:noreply, persist_control_status(state)}
        end

      _other ->
        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:run_queue, {:failed, _entry_id, issue_id, error_msg}}, state)
      when state.dispatch_mode == :queue do
    case Map.get(state.running, issue_id) do
      %{queue_entry_id: _entry_id} ->
        case pop_running_by_issue(state, issue_id) do
          {:ok, run_entry, state} ->
            cancel_run_timeout_timer(run_entry)
            error_result = {:error, %Result{status: :failed, error: error_msg}}

            {:noreply,
             state
             |> handle_runner_result(issue_id, run_entry, error_result)
             |> persist_control_status()}

          :error ->
            {:noreply, persist_control_status(state)}
        end

      _other ->
        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:run_queue, _event}, state) do
    {:noreply, state}
  end

  def handle_info({:run_worker_result, issue_id, worker_pid, result}, state)
      when is_binary(issue_id) and is_pid(worker_pid) do
    case Map.get(state.running, issue_id) do
      %{run_pid: ^worker_pid} ->
        case pop_running_by_issue(state, issue_id) do
          {:ok, run_entry, state} ->
            cancel_run_timeout_timer(run_entry)
            Process.demonitor(run_entry.run_ref, [:flush])

            {:noreply,
             state
             |> handle_runner_result(issue_id, run_entry, result)
             |> persist_control_status()}

          :error ->
            {:noreply, persist_control_status(state)}
        end

      _other ->
        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:queue_run_timeout, issue_id}, state) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{queue_entry_id: entry_id} when not is_nil(entry_id) ->
        case pop_running_by_issue(state, issue_id) do
          {:ok, run_entry, state} ->
            cancel_run_timeout_timer(run_entry)
            reason = "queued run timed out after #{state.run_timeout_ms || "configured"}ms"
            maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})
            RunQueue.cancel(entry_id)
            next_attempt = next_retry_attempt(run_entry.attempt)

            state
            |> tracker_mark_failed(issue_id, reason, next_attempt)
            |> schedule_retry_for_failed_run(issue_id, run_entry, next_attempt, reason)
            |> persist_control_status()
            |> then(&{:noreply, &1})

          :error ->
            {:noreply, persist_control_status(state)}
        end

      _other ->
        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:run_timeout, issue_id, run_pid, run_ref}, state)
      when is_binary(issue_id) and is_pid(run_pid) and is_reference(run_ref) do
    case Map.get(state.running, issue_id) do
      %{run_pid: ^run_pid, run_ref: ^run_ref} ->
        case pop_running_by_issue(state, issue_id) do
          {:ok, run_entry, state} ->
            cancel_run_timeout_timer(run_entry)
            Process.demonitor(run_entry.run_ref, [:flush])

            reason =
              "run timed out after #{state.run_timeout_ms || "configured"}ms without a result"

            maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})

            next_attempt = next_retry_attempt(run_entry.attempt)

            state
            |> stop_run_task(run_entry)
            |> tracker_mark_failed(issue_id, reason, next_attempt)
            |> schedule_retry_for_failed_run(issue_id, run_entry, next_attempt, reason)
            |> persist_control_status()
            |> then(&{:noreply, &1})

          :error ->
            {:noreply, persist_control_status(state)}
        end

      _other ->
        {:noreply, persist_control_status(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state)
      when is_reference(ref) and is_pid(pid) do
    if state.repo_sync_task_ref == ref and state.repo_sync_task_pid == pid do
      state = clear_repo_sync_task_state(state)

      case reason do
        :normal ->
          :ok

        :noproc ->
          :ok

        :killed ->
          :ok

        :shutdown ->
          :ok

        _other ->
          Logger.warning("Managed repo sync process exited: #{inspect(reason)}")
      end

      {:noreply, persist_control_status(state)}
    else
      handle_run_worker_down(state, ref, reason)
    end
  end

  defp handle_run_worker_down(state, ref, reason) do
    case pop_running_by_ref(state, ref) do
      {:ok, issue_id, run_entry, state} ->
        cancel_run_timeout_timer(run_entry)
        next_attempt = next_retry_attempt(run_entry.attempt)

        reason =
          "Run worker exited before returning a result: #{inspect(reason)}"

        maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})

        state = tracker_mark_failed(state, issue_id, reason, next_attempt)
        state = schedule_retry_for_failed_run(state, issue_id, run_entry, next_attempt, reason)
        {:noreply, persist_control_status(state)}

      :error ->
        {:noreply, persist_control_status(state)}
    end
  end

  # --- Poll cycle ---

  defp startup_reconcile(state) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         state <- reconcile_orphaned_step_retry_attempts(state, config),
         tracker <- resolve_tracker(state.tracker, config),
         {:ok, issues} <- list_active_issues(tracker, config) do
      in_progress_ids =
        issues
        |> Enum.filter(fn issue ->
          normalize_state(field(issue, :state)) == "in_progress"
        end)
        |> Enum.map(&issue_id/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      case state.dispatch_mode do
        :queue ->
          Enum.reduce(in_progress_ids, state, fn issue_id, acc ->
            has_active_queue_entry =
              case RunQueue.get_by_issue(issue_id) do
                nil -> false
                entry -> entry.status in ["pending", "claimed", "running"]
              end

            if has_active_queue_entry do
              claim(acc, issue_id)
            else
              Logger.info(
                "Resetting orphaned in_progress story issue_id=#{issue_id} to open for re-dispatch"
              )

              tracker_call(tracker, :mark_failed, [
                config,
                issue_id,
                "orphaned in_progress: no active queue entry on startup",
                1
              ])

              acc
            end
          end)

        :local ->
          Enum.reduce(in_progress_ids, state, fn issue_id, acc ->
            claim(acc, issue_id)
          end)
      end
    else
      {:error, reason} ->
        Logger.warning("Orchestrator startup reconciliation failed: #{reason}")
        state

      other ->
        Logger.warning("Orchestrator startup reconciliation skipped: #{inspect(other)}")
        state
    end
  end

  defp run_poll_cycle(state) do
    state =
      state
      |> refresh_maintenance_mode()
      |> maybe_sync_managed_repos()

    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         {:ok, issues} <- list_active_issues(tracker, config) do
      state
      |> prune_expired_ephemeral()
      |> apply_runtime_limits(config)
      |> refresh_project_limits()
      |> record_poll_heartbeat()
      |> clear_completed_for_open_issues(issues)
      |> reconcile_running(issues, config)
      |> prune_ineligible_retries(issues, config)
      |> prune_stale_open_claims(issues)
      |> detect_merges(config)
      |> dispatch_available(issues, config, tracker)
      |> Map.put(:last_error, nil)
    else
      {:error, reason} ->
        Logger.error("Orchestrator poll failed: #{reason}")

        state
        |> Map.put(:last_error, reason)
        |> record_poll_heartbeat()
    end
  end

  defp dispatch_retry(state, issue_id, retry_entry) do
    if state.maintenance_mode == :drain do
      defer_retry_due_to_maintenance(state, issue_id, retry_entry)
    else
      with {:ok, config} <- fetch_config(state.workflow_store),
           tracker <- resolve_tracker(state.tracker, config) do
        state = state |> apply_runtime_limits(config) |> refresh_project_limits()
        dispatch_retry_by_kind(state, issue_id, retry_entry, config, tracker)
      else
        {:error, reason} ->
          schedule_retry(
            state,
            issue_id,
            retry_entry.issue,
            retry_entry.attempt,
            "retry dispatch failed: #{reason}",
            retry_backoff_delay_ms(state, retry_entry.attempt),
            retry_schedule_opts(retry_entry)
          )
      end
    end
  end

  defp reconcile_orphaned_step_retry_attempts(state, config) do
    project_root = RunLogs.project_root(config)

    case RunLogs.reconcile_orphaned_step_retries(project_root) do
      {:ok, 0} ->
        state

      {:ok, count} ->
        Logger.warning(
          "Reconciled #{count} interrupted step-retry attempt(s) on startup project_root=#{project_root}"
        )

        state

      {:error, reason} ->
        Logger.warning("Failed to reconcile interrupted step retries on startup: #{reason}")
        state
    end
  end

  defp detect_merges(state, config) do
    tracker = resolve_tracker(state.tracker, config)

    case list_pending_merge_issues(tracker, config) do
      {:ok, pending_merge_issues} ->
        Enum.reduce(pending_merge_issues, state, fn issue, acc ->
          maybe_mark_issue_merged(acc, config, issue)
        end)

      {:error, reason} ->
        Logger.warning("Failed to list pending_merge issues: #{reason}")
        state
    end
  end

  defp maybe_mark_issue_merged(state, config, issue) do
    issue_id = issue_id(issue)
    pr_url = issue_pr_url(issue)

    if non_empty_string?(issue_id) and non_empty_string?(pr_url) do
      case merged?(state, config, pr_url) do
        {:ok, true} ->
          Logger.info("orchestrator_event=merge_detected issue_id=#{issue_id} pr_url=#{pr_url}")

          case tracker_mark_merged(state, issue_id, issue, %{pr_url: pr_url}) do
            {:ok, state} ->
              state

            {:error, reason, state} ->
              Logger.warning(
                "Failed to mark pending_merge issue as merged issue_id=#{issue_id}: #{reason}"
              )

              state
          end

        {:ok, false} ->
          state

        {:error, reason} ->
          Logger.warning(
            "Failed to check merge status issue_id=#{issue_id} pr_url=#{pr_url}: #{reason}"
          )

          state
      end
    else
      state
    end
  end

  defp merged?(state, config, pr_url) do
    case state.merge_checker do
      merge_checker when is_function(merge_checker, 2) ->
        merge_checker.(config, pr_url)

      _other ->
        default_merged_check(state, config, pr_url)
    end
  rescue
    error -> {:error, "merge checker failed: #{Exception.message(error)}"}
  end

  defp default_merged_check(state, config, pr_url) do
    provider = Config.effective_publish_provider(config)

    with {:ok, adapter} <- Publisher.module_for_provider(provider),
         {:ok, workspace} <- merge_check_workspace(state, config),
         response <- adapter.merged?(workspace, pr_url) do
      normalize_merged_response(response)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_check_workspace(state, config) do
    path =
      state.repo_local_path ||
        get_in(config, [Access.key(:workspace, %{}), Access.key(:source)])

    if non_empty_string?(path) do
      expanded = Path.expand(path)

      {:ok,
       %Workspace{
         path: expanded,
         key: "managed",
         root: Path.dirname(expanded),
         strategy: :clone,
         branch: nil
       }}
    else
      {:error, "cannot determine repository path for merge detection"}
    end
  end

  defp normalize_merged_response({:ok, value}) when is_boolean(value), do: {:ok, value}
  defp normalize_merged_response({:error, reason}), do: {:error, to_string(reason)}

  defp normalize_merged_response(other) do
    {:error, "invalid publisher merged? response: #{inspect(other)}"}
  end

  defp list_pending_merge_issues(tracker, _config) when is_function(tracker, 1), do: {:ok, []}

  defp list_pending_merge_issues(tracker, config) when is_atom(tracker) do
    if function_exported?(tracker, :list_pending_merge_issues, 1) do
      normalize_issue_response(tracker.list_pending_merge_issues(config))
    else
      {:ok, []}
    end
  rescue
    error ->
      {:error,
       "tracker module #{inspect(tracker)} failed in list_pending_merge_issues/1: #{Exception.message(error)}"}
  end

  defp list_pending_merge_issues(_tracker, _config), do: {:error, "invalid tracker adapter"}

  defp dispatch_retry_by_kind(state, issue_id, retry_entry, config, tracker) do
    case retry_kind(retry_entry) do
      :run ->
        dispatch_run_retry(state, issue_id, retry_entry, config, tracker)

      :agent_continuation ->
        dispatch_agent_continuation_retry(state, issue_id, retry_entry, config, tracker)

      :finalize_done ->
        dispatch_finalize_done_retry(state, issue_id, retry_entry)

      :finalize_resumable ->
        dispatch_finalize_resumable_retry(state, issue_id, retry_entry)

      :finalize_pending_merge ->
        dispatch_finalize_pending_merge_retry(state, issue_id, retry_entry)

      other ->
        Logger.warning(
          "Unknown retry kind for issue_id=#{issue_id}; releasing claim: #{inspect(other)}"
        )

        release_claim(state, issue_id)
    end
  end

  defp dispatch_run_retry(state, issue_id, retry_entry, config, tracker) do
    with {:ok, issues} <- list_active_issues(tracker, config) do
      issue = find_issue(issues, issue_id)

      if retry_attempt_reached_limit?(state, retry_entry.attempt) do
        stop_retry_after_limit(state, issue_id)
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

          project_running_count(state, issue, config) >=
              effective_project_max_concurrent_agents(state, issue, config) ->
            schedule_retry(
              state,
              issue_id,
              issue,
              retry_entry.attempt,
              "no available project slots",
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

  defp dispatch_agent_continuation_retry(state, issue_id, retry_entry, config, tracker) do
    with {:ok, issues} <- list_active_issues(tracker, config) do
      issue = find_issue(issues, issue_id)
      finalization = retry_finalization(retry_entry)

      if retry_attempt_reached_limit?(state, retry_entry.attempt) do
        stop_retry_after_limit(state, issue_id)
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
              retry_backoff_delay_ms(state, retry_entry.attempt),
              kind: :agent_continuation,
              finalization: finalization
            )

          true ->
            case validate_agent_continuation_finalization(finalization) do
              {:ok, continuation} ->
                case tracker_mark_resumable(
                       state,
                       issue_id,
                       continuation_tracker_metadata(continuation)
                     ) do
                  {:ok, state} ->
                    continuation_issue = put_issue_resumable(issue)

                    start_issue_run(
                      state,
                      continuation_issue,
                      retry_entry.attempt,
                      config,
                      tracker,
                      continuation_run_opts(continuation)
                    )

                  {:error, reason, state} ->
                    maybe_schedule_retry(
                      state,
                      issue_id,
                      retry_entry.issue,
                      next_retry_attempt(retry_entry.attempt),
                      "failed to mark issue resumable: #{reason}",
                      kind: :agent_continuation,
                      finalization: finalization
                    )
                end

              {:error, guidance} ->
                block_agent_phase_continuation_retry(
                  state,
                  issue_id,
                  retry_entry.attempt,
                  guidance
                )
            end
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
          retry_backoff_delay_ms(state, retry_entry.attempt),
          kind: :agent_continuation,
          finalization: retry_finalization(retry_entry)
        )
    end
  end

  defp dispatch_finalize_done_retry(state, issue_id, retry_entry) do
    if retry_attempt_reached_limit?(state, retry_entry.attempt) do
      stop_retry_after_limit(state, issue_id)
    else
      finalization = retry_finalization(retry_entry)
      done_metadata = Map.get(finalization, :done_metadata, %{})
      mark_merged? = Map.get(finalization, :mark_merged?, false)
      run_entry = Map.get(finalization, :run_entry)

      case finalize_done_run(state, issue_id, run_entry, done_metadata, mark_merged?) do
        {:ok, state} ->
          state

        {:error, reason, state} ->
          maybe_schedule_retry(
            state,
            issue_id,
            retry_entry.issue,
            next_retry_attempt(retry_entry.attempt),
            "failed to finalize successful run: #{reason}",
            kind: :finalize_done,
            finalization: finalization
          )
      end
    end
  end

  defp dispatch_finalize_resumable_retry(state, issue_id, retry_entry) do
    if retry_attempt_reached_limit?(state, retry_entry.attempt) do
      stop_retry_after_limit(state, issue_id)
    else
      finalization = retry_finalization(retry_entry)
      done_metadata = Map.get(finalization, :done_metadata, %{})
      continuation_attempt = Map.get(finalization, :continuation_attempt, 1)

      case tracker_mark_resumable(state, issue_id, done_metadata) do
        {:ok, state} ->
          schedule_retry(
            state,
            issue_id,
            retry_entry.issue,
            continuation_attempt,
            nil,
            state.continuation_delay_ms
          )

        {:error, reason, state} ->
          maybe_schedule_retry(
            state,
            issue_id,
            retry_entry.issue,
            next_retry_attempt(retry_entry.attempt),
            "failed to mark issue resumable: #{reason}",
            kind: :finalize_resumable,
            finalization: finalization
          )
      end
    end
  end

  defp dispatch_finalize_pending_merge_retry(state, issue_id, retry_entry) do
    if retry_attempt_reached_limit?(state, retry_entry.attempt) do
      stop_retry_after_limit(state, issue_id)
    else
      finalization = retry_finalization(retry_entry)
      pending_merge_metadata = Map.get(finalization, :pending_merge_metadata, %{})

      case finalize_pending_merge_run(state, issue_id, pending_merge_metadata) do
        {:ok, state} ->
          state

        {:error, reason, state} ->
          maybe_schedule_retry(
            state,
            issue_id,
            retry_entry.issue,
            next_retry_attempt(retry_entry.attempt),
            "failed to finalize pending-merge run: #{reason}",
            kind: :finalize_pending_merge,
            finalization: finalization
          )
      end
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

    state.completed
    |> MapSet.intersection(open_ids)
    |> Enum.reduce(state, fn issue_id, acc ->
      unmark_completed(acc, issue_id)
    end)
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
        |> drop_running(issue_id, run_entry.run_ref)
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

  defp prune_stale_open_claims(state, issues) do
    open_ids_without_active_run_or_retry =
      issues
      |> Enum.filter(fn issue ->
        issue_id = issue_id(issue)

        normalize_state(field(issue, :state)) == "open" and
          is_binary(issue_id) and
          not Map.has_key?(state.running, issue_id) and
          not Map.has_key?(state.retry_attempts, issue_id)
      end)
      |> Enum.map(&issue_id/1)
      |> MapSet.new()

    state.claimed
    |> MapSet.intersection(open_ids_without_active_run_or_retry)
    |> Enum.reduce(state, fn issue_id, acc ->
      release_claim(acc, issue_id)
    end)
  end

  defp dispatch_available(state, issues, config, tracker) do
    if state.maintenance_mode == :drain do
      state
    else
      available_slots = max(state.max_concurrent_agents - map_size(state.running), 0)

      if available_slots == 0 do
        state
      else
        {dispatch_candidates, next_rotation} =
          fair_dispatch_candidates(issues, state, config, available_slots)

        state = %{state | dispatch_rotation: next_rotation}

        Enum.reduce(dispatch_candidates, state, fn issue, acc ->
          start_issue_run(acc, issue, nil, config, tracker)
        end)
      end
    end
  end

  defp start_issue_run(state, issue, attempt, config, tracker, opts \\ %{}) do
    issue_id = issue_id(issue)
    identifier = issue_identifier(issue)
    opts = normalize_start_issue_run_opts(opts)
    retry_mode = normalize_retry_mode(Map.get(opts, :retry_mode, :full_rerun))
    retry_provenance = normalize_retry_provenance(Map.get(opts, :retry_provenance, %{}))
    retry_schedule_opts = start_issue_run_retry_schedule_opts(retry_mode, retry_provenance)

    with {:ok, resolved_story_execution} <- resolve_story_execution(config, issue),
         :ok <- tracker_prepare_issue_for_run(tracker, config, issue_id) do
      orchestrator_pid = self()
      {user_on_event, runner_opts} = Keyword.pop(state.runner_opts, :on_event)

      effective_config = resolved_story_execution.config

      metadata_overrides = %{
        "settings_snapshot" =>
          RunSettingsSnapshot.build(effective_config,
            workflow_identity:
              RunSettingsSnapshot.workflow_identity(state.workflow_store, effective_config)
          ),
        "run_settings" =>
          if(is_map(resolved_story_execution.settings_snapshot),
            do: resolved_story_execution.settings_snapshot,
            else: %{}
          )
      }

      run_log_context =
        prepare_run_log_context(config, issue, attempt,
          retry_mode: retry_mode,
          retry_provenance: retry_provenance,
          metadata_overrides: metadata_overrides
        )

      base_session_opts = if field(issue, :resumable), do: %{resumable: true}, else: %{}
      session_opts = Map.merge(base_session_opts, Map.get(opts, :session_opts, %{}))
      continuation = normalize_continuation_opts(Map.get(opts, :continuation))

      log_files =
        case run_log_context do
          %{files: files} -> files
          _ -> nil
        end

      run_opts =
        [
          workflow_store: state.workflow_store,
          config: resolved_story_execution.config,
          story_overrides_resolved: true,
          run_settings_snapshot: resolved_story_execution.settings_snapshot,
          attempt: attempt,
          session_opts: session_opts,
          continuation: continuation,
          log_files: log_files,
          on_event: runner_on_event(orchestrator_pid, issue_id, run_log_context, user_on_event)
        ] ++ runner_opts

      run_opts = maybe_put_prompt_template(run_opts, state.workflow_store)

      case state.dispatch_mode do
        :queue ->
          dispatch_to_queue(
            state,
            issue,
            issue_id,
            identifier,
            attempt,
            config,
            run_opts,
            run_log_context,
            retry_mode,
            retry_provenance,
            retry_schedule_opts
          )

        :local ->
          dispatch_locally(
            state,
            issue,
            issue_id,
            identifier,
            attempt,
            config,
            run_opts,
            run_log_context,
            retry_mode,
            retry_provenance,
            retry_schedule_opts,
            orchestrator_pid
          )
      end
    else
      {:error, {:story_overrides_invalid, reason}} ->
        retry_attempt = retry_attempt_from_run_attempt(attempt)
        failure_reason = "invalid story execution settings: #{reason}"

        state
        |> tracker_mark_failed(issue_id, failure_reason, retry_attempt)
        |> schedule_retry(
          issue_id,
          issue,
          retry_attempt,
          failure_reason,
          retry_backoff_delay_ms(state, retry_attempt),
          retry_schedule_opts
        )
        |> release_claim(issue_id)

      {:error, reason} ->
        retry_attempt = retry_attempt_from_run_attempt(attempt)

        state
        |> schedule_retry(
          issue_id,
          issue,
          retry_attempt,
          "tracker update failed before dispatch: #{reason}",
          retry_backoff_delay_ms(state, retry_attempt),
          retry_schedule_opts
        )
        |> release_claim(issue_id)
    end
  end

  defp dispatch_locally(
         state,
         issue,
         issue_id,
         identifier,
         attempt,
         config,
         run_opts,
         run_log_context,
         retry_mode,
         retry_provenance,
         retry_schedule_opts,
         orchestrator_pid
       ) do
    run_fun = fn -> invoke_runner(state.runner, issue, run_opts) end

    case start_run_worker(state.agent_pool, orchestrator_pid, issue_id, run_fun) do
      {:ok, run_pid} ->
        run_ref = Process.monitor(run_pid)
        run_timeout_timer_ref = schedule_run_timeout_timer(issue_id, run_pid, run_ref, state)
        runtime_profile = runtime_profile(config)

        run_entry = %{
          issue: issue,
          attempt: attempt,
          run_ref: run_ref,
          run_pid: run_pid,
          run_timeout_timer_ref: run_timeout_timer_ref,
          started_at: DateTime.utc_now(),
          runtime_profile: runtime_profile,
          runtime_process_state: initial_runtime_process_state(runtime_profile),
          runtime_last_event: nil,
          run_phase: RunPhase.from_status(:running),
          run_log_context: run_log_context,
          retry_mode: retry_mode,
          retry_provenance: retry_provenance
        }

        Logger.info(
          "Dispatching locally issue_id=#{issue_id} identifier=#{identifier} attempt=#{inspect(attempt)}"
        )

        state
        |> cancel_retry(issue_id)
        |> put_running(issue_id, run_entry)
        |> claim(issue_id)

      {:error, reason} ->
        retry_attempt = retry_attempt_from_run_attempt(attempt)
        failure_reason = "run worker failed to start: #{reason}"

        state
        |> tracker_mark_failed(issue_id, failure_reason, retry_attempt)
        |> schedule_retry(
          issue_id,
          issue,
          retry_attempt,
          failure_reason,
          retry_backoff_delay_ms(state, retry_attempt),
          retry_schedule_opts
        )
        |> release_claim(issue_id)
    end
  end

  defp dispatch_to_queue(
         state,
         issue,
         issue_id,
         identifier,
         attempt,
         config,
         run_opts,
         run_log_context,
         retry_mode,
         retry_provenance,
         retry_schedule_opts
       ) do
    serializable_run_opts = serialize_run_opts_for_queue(run_opts)
    issue_snapshot = serialize_issue_for_queue(issue)
    runtime_profile = runtime_profile(config)

    queue_attrs = %{
      issue_id: issue_id,
      identifier: identifier,
      priority: issue_priority(issue),
      attempt: attempt,
      config_snapshot: safe_json_encode(%{"issue" => issue_snapshot}),
      run_opts_snapshot: safe_json_encode(serializable_run_opts)
    }

    case RunQueue.enqueue(queue_attrs) do
      {:ok, entry} ->
        run_entry = %{
          issue: issue,
          attempt: attempt,
          run_ref: nil,
          run_pid: nil,
          run_timeout_timer_ref: schedule_queue_run_timeout_timer(issue_id, state),
          started_at: DateTime.utc_now(),
          runtime_profile: runtime_profile,
          runtime_process_state: initial_runtime_process_state(runtime_profile),
          runtime_last_event: nil,
          run_phase: RunPhase.from_status(:running),
          run_log_context: run_log_context,
          retry_mode: retry_mode,
          retry_provenance: retry_provenance,
          queue_entry_id: entry.id
        }

        Logger.info(
          "Dispatching to queue issue_id=#{issue_id} identifier=#{identifier} queue_entry=#{entry.id} attempt=#{inspect(attempt)}"
        )

        state
        |> cancel_retry(issue_id)
        |> put_running(issue_id, run_entry)
        |> claim(issue_id)

      {:error, changeset} ->
        retry_attempt = retry_attempt_from_run_attempt(attempt)
        failure_reason = "failed to enqueue run: #{inspect(changeset)}"

        state
        |> tracker_mark_failed(issue_id, failure_reason, retry_attempt)
        |> schedule_retry(
          issue_id,
          issue,
          retry_attempt,
          failure_reason,
          retry_backoff_delay_ms(state, retry_attempt),
          retry_schedule_opts
        )
        |> release_claim(issue_id)
    end
  end

  defp serialize_run_opts_for_queue(run_opts) do
    run_opts
    |> Enum.reject(fn {key, _} -> key in [:workflow_store, :on_event] end)
    |> Enum.map(fn
      {key, value} when is_function(value) -> {Atom.to_string(key), nil}
      {key, value} -> {Atom.to_string(key), make_json_safe(value)}
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp safe_json_encode(value) do
    safe = make_json_safe(value)

    case Jason.encode(safe) do
      {:ok, json} -> json
      {:error, _} -> inspect(value)
    end
  end

  defp make_json_safe(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__struct__])
    |> make_json_safe()
  end

  defp make_json_safe(value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), make_json_safe(v)}
      {k, v} -> {to_string(k), make_json_safe(v)}
    end)
  end

  defp make_json_safe(value) when is_list(value), do: Enum.map(value, &make_json_safe/1)

  defp make_json_safe(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp make_json_safe(value) when is_pid(value), do: inspect(value)
  defp make_json_safe(value) when is_reference(value), do: inspect(value)
  defp make_json_safe(value) when is_function(value), do: nil
  defp make_json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp make_json_safe(value), do: value

  defp serialize_issue_for_queue(issue) when is_map(issue) do
    issue
    |> Enum.into(%{}, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  rescue
    _ -> %{"id" => issue_id(issue)}
  end

  defp issue_priority(issue) do
    case field(issue, :priority) do
      p when is_integer(p) -> p
      _ -> 0
    end
  end

  defp schedule_queue_run_timeout_timer(issue_id, state) do
    timeout_ms = state.run_timeout_ms

    if is_integer(timeout_ms) and timeout_ms > 0 do
      Process.send_after(self(), {:queue_run_timeout, issue_id}, timeout_ms)
    else
      nil
    end
  end

  defp reconstruct_result_from_payload(nil) do
    now = DateTime.utc_now()
    {:error, %Result{status: :failed, error: "no result payload", started_at: now, ended_at: now}}
  end

  defp reconstruct_result_from_payload(payload) when is_map(payload) do
    now = DateTime.utc_now()

    status = parse_result_status(Map.get(payload, "status") || Map.get(payload, :status))
    events = decode_result_events(Map.get(payload, "events") || Map.get(payload, :events))

    result = %Result{
      status: status,
      error: Map.get(payload, "error"),
      issue_id: Map.get(payload, "issue_id"),
      identifier: Map.get(payload, "identifier"),
      workspace_path: Map.get(payload, "workspace_path"),
      turn_count: Map.get(payload, "turn_count", 0),
      last_output: Map.get(payload, "last_output"),
      events: events,
      started_at: parse_datetime(Map.get(payload, "started_at")) || now,
      ended_at: parse_datetime(Map.get(payload, "ended_at")) || now
    }

    if status in [:ok, :completed], do: {:ok, result}, else: {:error, result}
  end

  defp reconstruct_result_from_payload(_) do
    now = DateTime.utc_now()
    {:error, %Result{status: :failed, error: "invalid result", started_at: now, ended_at: now}}
  end

  defp parse_result_status(:ok), do: :ok
  defp parse_result_status(:completed), do: :completed
  defp parse_result_status(:max_turns_reached), do: :max_turns_reached
  defp parse_result_status("ok"), do: :ok
  defp parse_result_status("completed"), do: :completed
  defp parse_result_status("max_turns_reached"), do: :max_turns_reached
  defp parse_result_status(_status), do: :failed

  defp decode_result_events(events) when is_list(events), do: events
  defp decode_result_events(_events), do: []

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp resolve_dispatch_mode(:queue), do: :queue
  defp resolve_dispatch_mode("queue"), do: :queue
  defp resolve_dispatch_mode(_), do: :local

  defp resolve_story_execution(config, issue) do
    case StoryExecutionOverrides.resolve(config, issue) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:story_overrides_invalid, reason}}
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
      normalize_state(state_name) not in ["pending_merge", "merged"] and
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

  defp success_terminal_state?(state_name, _config) do
    normalize_state(state_name) == "merged"
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

  defp fair_dispatch_candidates(issues, state, config, available_slots)
       when is_integer(available_slots) and available_slots > 0 do
    eligible_issues =
      issues
      |> Enum.filter(&eligible_for_new_dispatch?(&1, state, config))
      |> sort_issues_for_dispatch()

    project_queues = Enum.group_by(eligible_issues, &issue_project_key(&1, config))
    running_counts = running_counts_by_project(state, config)

    project_remaining =
      Map.new(project_queues, fn {project_key, project_issues} ->
        representative_issue = List.first(project_issues)
        running_count = Map.get(running_counts, project_key, 0)

        project_limit =
          effective_project_max_concurrent_agents(state, representative_issue, config)

        {project_key, max(project_limit - running_count, 0)}
      end)

    project_order =
      project_queues
      |> Map.keys()
      |> Enum.sort()
      |> rotate_project_order(state.dispatch_rotation)

    dispatch_candidates =
      select_fair_issues(project_order, project_queues, project_remaining, available_slots, [])
      |> Enum.reverse()

    next_rotation =
      if dispatch_candidates == [] do
        state.dispatch_rotation
      else
        state.dispatch_rotation + 1
      end

    {dispatch_candidates, next_rotation}
  end

  defp fair_dispatch_candidates(_issues, state, _config, _available_slots),
    do: {[], state.dispatch_rotation}

  defp rotate_project_order([], _rotation), do: []

  defp rotate_project_order(project_order, rotation) do
    project_count = length(project_order)

    normalized_rotation =
      if is_integer(rotation) and rotation >= 0 do
        rotation
      else
        0
      end

    offset = rem(normalized_rotation, project_count)
    {leading_projects, trailing_projects} = Enum.split(project_order, offset)
    trailing_projects ++ leading_projects
  end

  defp select_fair_issues(_project_order, _queues, _remaining, available_slots, acc)
       when available_slots <= 0,
       do: acc

  defp select_fair_issues(project_order, queues, remaining, available_slots, acc) do
    {queues, remaining, available_slots, acc, dispatched_any?} =
      Enum.reduce(project_order, {queues, remaining, available_slots, acc, false}, fn
        _project_key, {queues_acc, remaining_acc, 0, acc_acc, dispatched_any?} ->
          {queues_acc, remaining_acc, 0, acc_acc, dispatched_any?}

        project_key, {queues_acc, remaining_acc, available_slots_acc, acc_acc, dispatched_any?} ->
          project_queue = Map.get(queues_acc, project_key, [])
          project_remaining = Map.get(remaining_acc, project_key, 0)

          cond do
            project_remaining <= 0 or project_queue == [] ->
              {queues_acc, remaining_acc, available_slots_acc, acc_acc, dispatched_any?}

            true ->
              [issue | rest] = project_queue

              {
                Map.put(queues_acc, project_key, rest),
                Map.put(remaining_acc, project_key, project_remaining - 1),
                available_slots_acc - 1,
                [issue | acc_acc],
                true
              }
          end
      end)

    cond do
      available_slots <= 0 ->
        acc

      dispatched_any? ->
        select_fair_issues(project_order, queues, remaining, available_slots, acc)

      true ->
        acc
    end
  end

  # --- Runner result handling ---

  defp handle_runner_result(state, issue_id, run_entry, {:ok, %Result{} = result}) do
    maybe_complete_run_logs(run_entry, result)
    state = mark_completed(state, issue_id)
    done_metadata = tracker_done_metadata(result, run_entry)

    case result.status do
      status when status in [:ok, :completed] ->
        mark_merged? = publish_merged?(result)
        mark_pending_merge? = publish_pending_merge?(result)

        with {:ok, state} <-
               finalize_successful_run(
                 state,
                 issue_id,
                 run_entry,
                 done_metadata,
                 mark_merged?,
                 mark_pending_merge?,
                 result
               ) do
          state
        else
          {:error, reason, state} ->
            next_attempt = next_retry_attempt(run_entry.attempt)

            {retry_kind, finalization} =
              successful_run_retry_payload(
                done_metadata,
                mark_merged?,
                mark_pending_merge?,
                result,
                run_entry
              )

            maybe_schedule_retry(
              state,
              issue_id,
              run_entry.issue,
              next_attempt,
              "failed to finalize successful run: #{reason}",
              kind: retry_kind,
              finalization: finalization
            )
        end

      :max_turns_reached ->
        next_attempt = next_retry_attempt(run_entry.attempt)
        failure_reason = result.error || "agent reached maximum configured turns"

        maybe_schedule_agent_phase_continuation_retry(
          state,
          issue_id,
          run_entry,
          next_attempt,
          failure_reason
        )

      _other ->
        next_attempt = next_retry_attempt(run_entry.attempt)
        reason = "runner returned non-success status: #{inspect(result.status)}"
        state = tracker_mark_failed(state, issue_id, reason, next_attempt)
        schedule_retry_for_failed_run(state, issue_id, run_entry, next_attempt, reason)
    end
  end

  defp handle_runner_result(state, issue_id, run_entry, {:error, %Result{} = result}) do
    maybe_complete_run_logs(run_entry, result)
    next_attempt = next_retry_attempt(run_entry.attempt)
    reason = result.error || "runner returned error"
    state = tracker_mark_failed(state, issue_id, reason, next_attempt)
    schedule_retry_for_failed_run(state, issue_id, run_entry, next_attempt, reason)
  end

  defp handle_runner_result(state, issue_id, run_entry, other_result) do
    reason = "runner returned unexpected result: #{inspect(other_result)}"

    maybe_complete_run_logs(run_entry, %{status: :failed, error: reason})

    next_attempt = next_retry_attempt(run_entry.attempt)
    state = tracker_mark_failed(state, issue_id, reason, next_attempt)
    schedule_retry_for_failed_run(state, issue_id, run_entry, next_attempt, reason)
  end

  defp finalize_successful_run(
         state,
         issue_id,
         run_entry,
         done_metadata,
         mark_merged?,
         mark_pending_merge?,
         result
       ) do
    cond do
      mark_merged? ->
        finalize_done_run(state, issue_id, run_entry, done_metadata, true)

      mark_pending_merge? ->
        pending_merge_metadata = pending_merge_metadata(result, done_metadata)
        finalize_pending_merge_run(state, issue_id, pending_merge_metadata)

      true ->
        finalize_done_run(state, issue_id, run_entry, done_metadata, false)
    end
  end

  defp finalize_done_run(state, issue_id, run_entry, done_metadata, mark_merged?)
       when is_boolean(mark_merged?) do
    with {:ok, state} <- tracker_mark_done(state, issue_id, done_metadata, run_entry),
         {:ok, state} <-
           maybe_tracker_mark_merged(
             state,
             issue_id,
             run_entry_issue(run_entry),
             mark_merged?,
             done_metadata
           ) do
      {:ok, state}
    end
  end

  defp schedule_retry_for_failed_run(state, issue_id, run_entry, attempt, reason) do
    if state.retries_enabled and agent_phase_continuation_candidate?(run_entry) do
      maybe_schedule_agent_phase_continuation_retry(state, issue_id, run_entry, attempt, reason)
    else
      maybe_schedule_retry(state, issue_id, run_entry.issue, attempt, reason)
    end
  end

  defp maybe_schedule_agent_phase_continuation_retry(
         state,
         issue_id,
         run_entry,
         attempt,
         failure_reason
       ) do
    case build_agent_continuation_finalization(state, run_entry, attempt, failure_reason) do
      {:ok, finalization} ->
        schedule_retry(
          state,
          issue_id,
          run_entry.issue,
          attempt,
          failure_reason,
          state.continuation_delay_ms,
          kind: :agent_continuation,
          finalization: finalization
        )

      {:error, guidance} ->
        block_agent_phase_continuation_retry(state, issue_id, attempt, guidance)
    end
  end

  defp block_agent_phase_continuation_retry(state, issue_id, attempt, guidance) do
    actionable_reason =
      "agent-phase continuation retry blocked: #{guidance}. Trigger a full rerun manually."

    Logger.warning(
      "Blocking agent continuation retry issue_id=#{issue_id} attempt=#{attempt}: #{actionable_reason}"
    )

    state
    |> cancel_retry(issue_id)
    |> tracker_mark_failed(issue_id, actionable_reason, attempt)
    |> release_claim(issue_id)
    |> mark_completed(issue_id)
  end

  defp build_agent_continuation_finalization(
         state,
         run_entry,
         continuation_attempt,
         failure_reason
       ) do
    with {:ok, originating_attempt} <- originating_run_log_attempt(run_entry),
         {:ok, workspace_path} <- continuation_workspace_path(state, run_entry),
         :ok <- ensure_continuation_workspace(workspace_path),
         {:ok, events_path} <- continuation_events_path(run_entry),
         {:ok, events} <- read_run_log_events(events_path),
         {:ok, last_successful_turn} <- last_successful_turn(events, run_entry) do
      continuation = %{
        mode: "agent_continuation",
        source: "agent_phase_failure",
        originating_attempt: originating_attempt,
        continuation_attempt: continuation_attempt,
        last_successful_turn: last_successful_turn,
        failure_reason: failure_reason,
        originating_session_id: originating_session_id(events),
        workspace_path: workspace_path,
        events_path: events_path,
        generated_at: DateTime.utc_now()
      }

      {:ok, %{continuation: continuation}}
    end
  end

  defp validate_agent_continuation_finalization(finalization) when is_map(finalization) do
    continuation = field(finalization, :continuation)

    with continuation when is_map(continuation) <- continuation,
         originating_attempt when is_integer(originating_attempt) and originating_attempt > 0 <-
           positive_integer(field(continuation, :originating_attempt), nil),
         last_successful_turn when is_integer(last_successful_turn) and last_successful_turn > 0 <-
           positive_integer(field(continuation, :last_successful_turn), nil),
         failure_reason <- field(continuation, :failure_reason),
         true <- is_binary(failure_reason) and byte_size(failure_reason) > 0,
         workspace_path <- field(continuation, :workspace_path),
         true <- is_binary(workspace_path) and byte_size(workspace_path) > 0,
         true <- File.dir?(workspace_path),
         events_path <- field(continuation, :events_path),
         true <- is_binary(events_path) and byte_size(events_path) > 0,
         true <- File.exists?(events_path) do
      {:ok,
       %{
         mode: "agent_continuation",
         source: field(continuation, :source) || "agent_phase_failure",
         originating_attempt: originating_attempt,
         continuation_attempt:
           positive_integer(field(continuation, :continuation_attempt), originating_attempt + 1),
         last_successful_turn: last_successful_turn,
         failure_reason: failure_reason,
         originating_session_id: field(continuation, :originating_session_id),
         workspace_path: workspace_path,
         events_path: events_path,
         generated_at: field(continuation, :generated_at) || DateTime.utc_now()
       }}
    else
      nil ->
        {:error, "retry provenance is missing; a full rerun is required"}

      false ->
        {:error,
         "workspace/log prerequisites are unavailable; keep the workspace and run logs intact before retrying"}

      _other ->
        {:error, "retry provenance is incomplete; a full rerun is required"}
    end
  end

  defp validate_agent_continuation_finalization(_finalization) do
    {:error, "retry provenance is invalid; a full rerun is required"}
  end

  defp continuation_tracker_metadata(continuation) when is_map(continuation) do
    %{
      status: :agent_continuation_scheduled,
      retry_mode: "agent_continuation",
      retry_provenance: continuation,
      originating_attempt: Map.get(continuation, :originating_attempt),
      last_successful_turn: Map.get(continuation, :last_successful_turn),
      failure_reason: Map.get(continuation, :failure_reason)
    }
  end

  defp continuation_tracker_metadata(_continuation),
    do: %{status: :agent_continuation_scheduled, retry_mode: "agent_continuation"}

  defp continuation_run_opts(continuation) when is_map(continuation) do
    %{
      # Force a fresh adapter session and rely on workspace/log-derived continuation context.
      session_opts: %{resumable: false},
      continuation: %{
        mode: :agent_continuation,
        originating_attempt: Map.get(continuation, :originating_attempt),
        last_successful_turn: Map.get(continuation, :last_successful_turn),
        failure_reason: Map.get(continuation, :failure_reason),
        originating_session_id: Map.get(continuation, :originating_session_id)
      },
      retry_mode: :agent_continuation,
      retry_provenance: continuation
    }
  end

  defp continuation_run_opts(_continuation) do
    %{session_opts: %{resumable: false}, retry_mode: :agent_continuation, retry_provenance: %{}}
  end

  defp put_issue_resumable(issue) when is_map(issue) do
    issue
    |> Map.put(:resumable, true)
    |> Map.put("resumable", true)
  end

  defp put_issue_resumable(issue), do: issue

  defp agent_phase_continuation_candidate?(run_entry) when is_map(run_entry) do
    run_phase = Map.get(run_entry, :run_phase)
    previous_run_phase = Map.get(run_entry, :previous_run_phase)

    run_phase_kind(run_phase) == "agent" or
      run_phase_event_type(run_phase) == "turn_failed" or
      run_phase_event_type(previous_run_phase) == "turn_failed" or
      run_finished_after_agent_phase?(run_phase, previous_run_phase)
  end

  defp agent_phase_continuation_candidate?(_run_entry), do: false

  defp run_finished_after_agent_phase?(run_phase, previous_run_phase) do
    run_phase_event_type(run_phase) == "run_finished" and
      run_phase_kind(previous_run_phase) == "agent"
  end

  defp run_phase_kind(%{} = run_phase) do
    case field(run_phase, :kind) do
      kind when is_binary(kind) -> kind
      kind when is_atom(kind) -> Atom.to_string(kind)
      _other -> nil
    end
  end

  defp run_phase_kind(_run_phase), do: nil

  defp run_phase_event_type(%{} = run_phase) do
    case field(run_phase, :event_type) do
      event_type when is_binary(event_type) -> event_type
      event_type when is_atom(event_type) -> Atom.to_string(event_type)
      _other -> nil
    end
  end

  defp run_phase_event_type(_run_phase), do: nil

  defp originating_run_log_attempt(run_entry) when is_map(run_entry) do
    case get_in(run_entry, [:run_log_context, :attempt]) do
      attempt when is_integer(attempt) and attempt > 0 ->
        {:ok, attempt}

      _other ->
        {:error, "originating run attempt metadata is missing"}
    end
  end

  defp originating_run_log_attempt(_run_entry),
    do: {:error, "originating run attempt metadata is missing"}

  defp continuation_workspace_path(state, run_entry) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         identifier <- issue_identifier(run_entry.issue),
         true <- is_binary(identifier) and byte_size(identifier) > 0 do
      workspace_root =
        config
        |> get_in([Access.key(:workspace, %{}), Access.key(:root)])
        |> case do
          root when is_binary(root) and byte_size(root) > 0 ->
            expand_workspace_root(root)

          _other ->
            Kollywood.ServiceConfig.workspaces_dir()
        end

      {:ok, Path.join(workspace_root, Workspace.sanitize_key(identifier))}
    else
      {:error, reason} ->
        {:error, "workflow config unavailable while resolving workspace: #{reason}"}

      _other ->
        {:error, "issue identifier is missing; cannot compute workspace for continuation"}
    end
  end

  defp ensure_continuation_workspace(path) when is_binary(path) do
    if File.dir?(path) do
      :ok
    else
      {:error, "workspace not found at #{path}"}
    end
  end

  defp ensure_continuation_workspace(_path), do: {:error, "workspace path is unavailable"}

  defp continuation_events_path(run_entry) when is_map(run_entry) do
    case get_in(run_entry, [:run_log_context, :files, :events]) do
      path when is_binary(path) and byte_size(path) > 0 ->
        {:ok, path}

      _other ->
        {:error, "run-log events file is missing"}
    end
  end

  defp continuation_events_path(_run_entry), do: {:error, "run-log events file is missing"}

  defp read_run_log_events(path) when is_binary(path) do
    if File.exists?(path) do
      events =
        path
        |> File.stream!([], :line)
        |> Enum.reduce([], fn line, acc ->
          case Jason.decode(String.trim(line)) do
            {:ok, event} when is_map(event) -> [event | acc]
            _other -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, events}
    else
      {:error, "run-log events file not found: #{path}"}
    end
  rescue
    error ->
      {:error, "failed to read run-log events: #{Exception.message(error)}"}
  end

  defp read_run_log_events(_path), do: {:error, "run-log events path is invalid"}

  defp last_successful_turn(events, run_entry) when is_list(events) do
    case last_successful_turn_from_events(events) do
      {:ok, turn} ->
        {:ok, turn}

      {:error, _reason} ->
        last_successful_turn_from_metadata(run_entry)
    end
  end

  defp last_successful_turn(_events, run_entry), do: last_successful_turn_from_metadata(run_entry)

  defp last_successful_turn_from_events(events) when is_list(events) do
    events
    |> Enum.filter(fn event -> event_type(event) == "turn_succeeded" end)
    |> Enum.map(fn event -> positive_integer(field(event, :turn), nil) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
    |> case do
      turn when is_integer(turn) and turn > 0 -> {:ok, turn}
      _other -> {:error, "turn_succeeded events are missing"}
    end
  end

  defp last_successful_turn_from_events(_events), do: {:error, "run-log events are unavailable"}

  defp last_successful_turn_from_metadata(run_entry) when is_map(run_entry) do
    metadata_path = get_in(run_entry, [:run_log_context, :files, :metadata])

    with path when is_binary(path) and byte_size(path) > 0 <- metadata_path,
         true <- File.exists?(path),
         {:ok, metadata} <- read_json_file(path),
         last_successful_turn when is_integer(last_successful_turn) and last_successful_turn > 0 <-
           positive_integer(field(metadata, :last_successful_turn), nil) do
      {:ok, last_successful_turn}
    else
      _other ->
        {:error,
         "no successful turn could be derived from run logs; cannot resume agent-phase retry safely"}
    end
  end

  defp last_successful_turn_from_metadata(_run_entry) do
    {:error, "run-log metadata is unavailable for continuation retry"}
  end

  defp read_json_file(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _other -> {:error, "invalid JSON"}
    end
  end

  defp read_json_file(_path), do: {:error, "invalid path"}

  defp originating_session_id(events) when is_list(events) do
    events
    |> Enum.filter(fn event ->
      type = event_type(event)
      type in ["execution_session_started", "session_started"]
    end)
    |> Enum.map(&field(&1, :session_id))
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  defp originating_session_id(_events), do: nil

  defp event_type(event) when is_map(event) do
    case field(event, :type) do
      value when is_binary(value) -> value
      value when is_atom(value) -> Atom.to_string(value)
      _other -> ""
    end
  end

  defp event_type(_event), do: ""

  defp expand_workspace_root(root) do
    root
    |> to_string()
    |> String.replace_prefix("~", System.user_home!())
    |> Path.expand()
  end

  defp normalize_start_issue_run_opts(opts) when is_map(opts), do: opts

  defp normalize_start_issue_run_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Map.new(opts), else: %{}
  end

  defp normalize_start_issue_run_opts(_opts), do: %{}

  defp start_issue_run_retry_schedule_opts(:agent_continuation, retry_provenance) do
    [kind: :agent_continuation, finalization: continuation_retry_finalization(retry_provenance)]
  end

  defp start_issue_run_retry_schedule_opts(_retry_mode, _retry_provenance), do: []

  defp continuation_retry_finalization(retry_provenance) when is_map(retry_provenance) do
    case field(retry_provenance, :continuation) do
      continuation when is_map(continuation) -> %{continuation: continuation}
      _other -> %{continuation: retry_provenance}
    end
  end

  defp continuation_retry_finalization(_retry_provenance), do: %{continuation: %{}}

  defp normalize_retry_mode(mode) when mode in [:full_rerun, :agent_continuation], do: mode
  defp normalize_retry_mode("agent_continuation"), do: :agent_continuation
  defp normalize_retry_mode("agent-continuation"), do: :agent_continuation
  defp normalize_retry_mode(_mode), do: :full_rerun

  defp normalize_retry_provenance(provenance) when is_map(provenance), do: provenance
  defp normalize_retry_provenance(_provenance), do: %{}

  defp normalize_continuation_opts(nil), do: nil
  defp normalize_continuation_opts(opts) when is_map(opts), do: opts

  defp normalize_continuation_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Map.new(opts), else: nil
  end

  defp normalize_continuation_opts(_opts), do: nil

  # --- Retry and claim management ---

  defp maybe_schedule_retry(state, issue_id, issue, attempt, reason, opts \\ []) do
    cond do
      not is_nil(state.max_attempts) and attempt >= state.max_attempts ->
        Logger.warning(
          "Max attempts (#{state.max_attempts}) reached for issue_id=#{issue_id}; stopping: #{reason}"
        )

        state
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
        |> mark_completed(issue_id)

      state.retries_enabled ->
        schedule_retry(
          state,
          issue_id,
          issue,
          attempt,
          reason,
          retry_backoff_delay_ms(state, attempt),
          opts
        )

      true ->
        Logger.warning(
          "Retries disabled for issue_id=#{issue_id}; stopping retries after failure: #{reason}"
        )

        state
        |> cancel_retry(issue_id)
        |> release_claim(issue_id)
        |> mark_completed(issue_id)
    end
  end

  defp schedule_retry(state, issue_id, issue, attempt, reason, delay_ms, opts \\ []) do
    if state.retries_enabled do
      state = cancel_retry(state, issue_id)
      due_at_ms = System.monotonic_time(:millisecond) + delay_ms
      timer_ref = Process.send_after(self(), {:retry_due, issue_id}, delay_ms)
      kind = normalize_retry_kind(Keyword.get(opts, :kind, :run))
      finalization = Keyword.get(opts, :finalization)

      if reason do
        Logger.warning(
          "Scheduling retry issue_id=#{issue_id} attempt=#{attempt} delay_ms=#{delay_ms} kind=#{kind} reason=#{reason}"
        )
      else
        Logger.info("Scheduling continuation issue_id=#{issue_id} delay_ms=#{delay_ms}")
      end

      retry_entry = %{
        issue: issue,
        attempt: attempt,
        reason: reason,
        kind: kind,
        finalization: finalization,
        timer_ref: timer_ref,
        due_at_ms: due_at_ms
      }

      state =
        %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, retry_entry)}
        |> claim(issue_id)

      persist_retry_entry(state, issue_id, retry_entry)
    else
      Logger.warning(
        "Retries disabled for issue_id=#{issue_id}; not scheduling retry#{if reason, do: " reason=#{reason}", else: ""}"
      )

      state
      |> cancel_retry(issue_id)
      |> release_claim(issue_id)
    end
  end

  defp defer_retry_due_to_maintenance(state, issue_id, retry_entry) do
    delay_ms = max(state.continuation_delay_ms, @maintenance_retry_defer_ms)
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    timer_ref = Process.send_after(self(), {:retry_due, issue_id}, delay_ms)

    deferred_entry =
      retry_entry
      |> Map.put(:timer_ref, timer_ref)
      |> Map.put(:due_at_ms, due_at_ms)

    state =
      %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, deferred_entry)}
      |> claim(issue_id)

    persist_retry_entry(state, issue_id, deferred_entry)
  end

  defp retry_kind(retry_entry) when is_map(retry_entry),
    do: normalize_retry_kind(Map.get(retry_entry, :kind, :run))

  defp retry_kind(_retry_entry), do: :run

  defp retry_finalization(retry_entry) when is_map(retry_entry),
    do: Map.get(retry_entry, :finalization) || %{}

  defp retry_finalization(_retry_entry), do: %{}

  defp retry_schedule_opts(retry_entry) do
    kind = retry_kind(retry_entry)
    finalization = retry_finalization(retry_entry)

    if kind == :run do
      []
    else
      [kind: kind, finalization: finalization]
    end
  end

  defp normalize_retry_kind(kind)
       when kind in [
              :run,
              :agent_continuation,
              :finalize_done,
              :finalize_resumable,
              :finalize_pending_merge
            ],
       do: kind

  defp normalize_retry_kind("run"), do: :run
  defp normalize_retry_kind("agent_continuation"), do: :agent_continuation
  defp normalize_retry_kind("agent-continuation"), do: :agent_continuation
  defp normalize_retry_kind("finalize_done"), do: :finalize_done
  defp normalize_retry_kind("finalize_resumable"), do: :finalize_resumable
  defp normalize_retry_kind("finalize_pending_merge"), do: :finalize_pending_merge
  defp normalize_retry_kind(_kind), do: :run

  defp normalize_ephemeral_kind(kind) when kind in [:claimed, :completed], do: kind
  defp normalize_ephemeral_kind("completed"), do: :completed
  defp normalize_ephemeral_kind(_kind), do: :claimed

  defp retry_run_entry(run_entry) when is_map(run_entry) do
    run_log_entry =
      case Map.get(run_entry, :run_log_context) do
        nil -> %{}
        run_log_context -> %{run_log_context: run_log_context}
      end

    issue_entry =
      run_entry
      |> run_entry_issue()
      |> case do
        nil ->
          %{}

        issue ->
          %{
            issue: %{
              id: issue_id(issue),
              identifier: issue_identifier(issue)
            }
          }
      end

    Map.merge(run_log_entry, issue_entry)
  end

  defp retry_run_entry(_run_entry), do: %{}

  defp persist_retry_entry(state, issue_id, retry_entry) do
    case state.retry_store do
      nil ->
        state

      retry_store ->
        retry_entry =
          retry_entry
          |> Map.drop([:timer_ref])
          |> Map.update(:kind, :run, &normalize_retry_kind/1)

        case retry_store.upsert(issue_id, retry_entry) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("Failed to persist retry issue_id=#{issue_id}: #{reason}")
            state
        end
    end
  rescue
    error ->
      Logger.warning("Failed to persist retry issue_id=#{issue_id}: #{Exception.message(error)}")

      state
  end

  defp delete_persisted_retry(state, issue_id) do
    case state.retry_store do
      nil ->
        state

      retry_store ->
        case retry_store.delete(issue_id) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("Failed to delete persisted retry issue_id=#{issue_id}: #{reason}")
            state
        end
    end
  rescue
    error ->
      Logger.warning(
        "Failed to delete persisted retry issue_id=#{issue_id}: #{Exception.message(error)}"
      )

      state
  end

  defp retry_attempt_reached_limit?(state, attempt) do
    not is_nil(state.max_attempts) and attempt >= state.max_attempts
  end

  defp stop_retry_after_limit(state, issue_id) do
    Logger.warning(
      "Max attempts (#{state.max_attempts}) reached for issue_id=#{issue_id} on retry dispatch; stopping"
    )

    state
    |> cancel_retry(issue_id)
    |> release_claim(issue_id)
    |> mark_completed(issue_id)
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

  defp claim(state, issue_id) when is_binary(issue_id) do
    expires_at_ms = System.monotonic_time(:millisecond) + state.claim_ttl_ms
    claim_with_expiry(state, issue_id, expires_at_ms)
  end

  defp claim(state, _issue_id), do: state

  defp claim_with_expiry(state, issue_id, expires_at_ms)
       when is_binary(issue_id) and is_integer(expires_at_ms) do
    state = %{
      state
      | claimed: MapSet.put(state.claimed, issue_id),
        claimed_until: Map.put(state.claimed_until, issue_id, expires_at_ms)
    }

    persist_ephemeral_entry(state, :claimed, issue_id, expires_at_ms)
  end

  defp claim_with_expiry(state, _issue_id, _expires_at_ms), do: state

  defp release_claim(state, issue_id) when is_binary(issue_id) do
    state = %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        claimed_until: Map.delete(state.claimed_until, issue_id)
    }

    delete_persisted_ephemeral_entry(state, :claimed, issue_id)
  end

  defp release_claim(state, _issue_id), do: state

  defp mark_completed(state, issue_id) when is_binary(issue_id) do
    expires_at_ms = System.monotonic_time(:millisecond) + state.completed_ttl_ms

    state = %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        completed_until: Map.put(state.completed_until, issue_id, expires_at_ms)
    }

    persist_ephemeral_entry(state, :completed, issue_id, expires_at_ms)
  end

  defp mark_completed(state, _issue_id), do: state

  defp unmark_completed(state, issue_id) when is_binary(issue_id) do
    state = %{
      state
      | completed: MapSet.delete(state.completed, issue_id),
        completed_until: Map.delete(state.completed_until, issue_id)
    }

    delete_persisted_ephemeral_entry(state, :completed, issue_id)
  end

  defp unmark_completed(state, _issue_id), do: state

  defp prune_expired_ephemeral(state) do
    now_ms = System.monotonic_time(:millisecond)

    expired_claimed_ids =
      state.claimed_until
      |> Enum.filter(fn {_issue_id, expires_at_ms} -> expires_at_ms <= now_ms end)
      |> Enum.map(fn {issue_id, _expires_at_ms} -> issue_id end)

    expired_completed_ids =
      state.completed_until
      |> Enum.filter(fn {_issue_id, expires_at_ms} -> expires_at_ms <= now_ms end)
      |> Enum.map(fn {issue_id, _expires_at_ms} -> issue_id end)

    state = Enum.reduce(expired_claimed_ids, state, &release_claim(&2, &1))
    Enum.reduce(expired_completed_ids, state, &unmark_completed(&2, &1))
  end

  defp persist_ephemeral_entry(state, kind, issue_id, expires_at_ms) do
    case state.ephemeral_store do
      nil ->
        state

      ephemeral_store ->
        case ephemeral_store.upsert(kind, issue_id, expires_at_ms) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("Failed to persist #{kind} marker issue_id=#{issue_id}: #{reason}")

            state
        end
    end
  rescue
    error ->
      Logger.warning(
        "Failed to persist #{kind} marker issue_id=#{issue_id}: #{Exception.message(error)}"
      )

      state
  end

  defp delete_persisted_ephemeral_entry(state, kind, issue_id) do
    case state.ephemeral_store do
      nil ->
        state

      ephemeral_store ->
        case ephemeral_store.delete(kind, issue_id) do
          :ok ->
            state

          {:error, reason} ->
            Logger.warning("Failed to delete #{kind} marker issue_id=#{issue_id}: #{reason}")

            state
        end
    end
  rescue
    error ->
      Logger.warning(
        "Failed to delete #{kind} marker issue_id=#{issue_id}: #{Exception.message(error)}"
      )

      state
  end

  defp cancel_retry(state, issue_id) do
    state = delete_persisted_retry(state, issue_id)

    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        state

      {retry_entry, retry_attempts} ->
        Process.cancel_timer(retry_entry.timer_ref)
        %{state | retry_attempts: retry_attempts}
    end
  end

  defp start_run_worker(agent_pool, orchestrator_pid, issue_id, run_fun)
       when is_function(run_fun, 0) do
    case AgentPool.start_run(agent_pool,
           orchestrator: orchestrator_pid,
           issue_id: issue_id,
           run_fun: run_fun
         ) do
      {:ok, run_pid} ->
        {:ok, run_pid}

      {:ok, run_pid, _info} ->
        {:ok, run_pid}

      :ignore ->
        {:error, "run worker ignored start request"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  rescue
    error ->
      {:error, Exception.message(error)}
  catch
    :exit, reason ->
      {:error, Exception.format_exit(reason)}
  end

  # --- Running workers ---

  defp put_running(state, issue_id, %{run_ref: nil} = run_entry) do
    %{state | running: Map.put(state.running, issue_id, run_entry)}
  end

  defp put_running(state, issue_id, run_entry) do
    %{
      state
      | running: Map.put(state.running, issue_id, run_entry),
        running_by_ref: Map.put(state.running_by_ref, run_entry.run_ref, issue_id)
    }
  end

  defp drop_running(state, issue_id, nil) do
    %{state | running: Map.delete(state.running, issue_id)}
  end

  defp drop_running(state, issue_id, run_ref) do
    %{
      state
      | running: Map.delete(state.running, issue_id),
        running_by_ref: Map.delete(state.running_by_ref, run_ref)
    }
  end

  defp pop_running_by_issue(state, issue_id) do
    case Map.pop(state.running, issue_id) do
      {nil, _running} ->
        :error

      {run_entry, running} ->
        {:ok, run_entry,
         %{
           state
           | running: running,
             running_by_ref: Map.delete(state.running_by_ref, run_entry.run_ref)
         }}
    end
  end

  defp pop_running_by_ref(state, run_ref) do
    case Map.pop(state.running_by_ref, run_ref) do
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

  defp schedule_run_timeout_timer(issue_id, run_pid, run_ref, state) do
    case state.run_timeout_ms do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        Process.send_after(self(), {:run_timeout, issue_id, run_pid, run_ref}, timeout_ms)

      _other ->
        nil
    end
  end

  defp cancel_run_timeout_timer(run_entry) when is_map(run_entry) do
    case Map.get(run_entry, :run_timeout_timer_ref) do
      ref when is_reference(ref) ->
        Process.cancel_timer(ref)
        :ok

      _other ->
        :ok
    end
  end

  defp cancel_run_timeout_timer(_run_entry), do: :ok

  defp stop_run_task(state, run_entry) do
    cancel_run_timeout_timer(run_entry)

    case Map.get(run_entry, :run_pid) do
      pid when is_pid(pid) ->
        _ = AgentPool.stop_run(state.agent_pool, pid)

      nil ->
        case Map.get(run_entry, :queue_entry_id) do
          entry_id when not is_nil(entry_id) -> RunQueue.cancel(entry_id)
          _ -> :ok
        end
    end

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
        |> drop_running(issue_id, run_entry.run_ref)
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
          current_phase = Map.get(run_entry, :run_phase)
          next_phase = RunPhase.from_event(event, current_phase)

          {runtime_process_state, runtime_last_event} =
            runtime_state_from_event(run_entry, event)

          updated_entry =
            run_entry
            |> Map.put(:runtime_process_state, runtime_process_state)
            |> Map.put(:runtime_last_event, runtime_last_event)
            |> Map.put(:previous_run_phase, current_phase)
            |> Map.put(:run_phase, next_phase)

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

  defp resolve_ephemeral_store(:__default__) do
    Application.get_env(:kollywood, :orchestrator_ephemeral_store, EphemeralStore)
  end

  defp resolve_ephemeral_store(nil), do: nil

  defp resolve_ephemeral_store(ephemeral_store) when is_atom(ephemeral_store), do: ephemeral_store

  defp resolve_ephemeral_store(_ephemeral_store), do: nil

  defp resolve_retry_store(:__default__) do
    Application.get_env(:kollywood, :orchestrator_retry_store, RetryStore)
  end

  defp resolve_retry_store(nil), do: nil

  defp resolve_retry_store(retry_store) when is_atom(retry_store), do: retry_store

  defp resolve_retry_store(_retry_store), do: nil

  defp resolve_agent_pool(agent_pool) when is_pid(agent_pool), do: {:ok, agent_pool}

  defp resolve_agent_pool(agent_pool) when is_atom(agent_pool) do
    if Process.whereis(agent_pool) do
      {:ok, agent_pool}
    else
      AgentPool.start_link(name: agent_pool)
    end
  end

  defp resolve_agent_pool(_agent_pool), do: {:error, "invalid agent pool configuration"}

  defp cleanup_orphan_workers(state) do
    with {:ok, children} <- list_agent_pool_children(state.agent_pool),
         orphan_pids when orphan_pids != [] <- worker_child_pids(children) do
      Logger.warning(
        "Stopping #{length(orphan_pids)} orphan run worker(s) during orchestrator startup"
      )

      Enum.each(orphan_pids, fn pid ->
        _ = AgentPool.stop_run(state.agent_pool, pid)
      end)

      state
    else
      [] ->
        state

      {:error, reason} ->
        Logger.warning("Failed to inspect agent pool children: #{reason}")
        state
    end
  end

  defp restore_persisted_ephemeral_state(%__MODULE__{ephemeral_store: nil} = state), do: state

  defp restore_persisted_ephemeral_state(state) do
    now_ms = System.monotonic_time(:millisecond)

    case state.ephemeral_store.list_active(now_ms) do
      {:ok, entries} ->
        Enum.reduce(entries, state, &restore_ephemeral_entry(&2, &1))

      {:error, reason} ->
        Logger.warning("Failed to restore persisted ephemeral state: #{reason}")
        state
    end
  rescue
    error ->
      Logger.warning("Failed to restore persisted ephemeral state: #{Exception.message(error)}")
      state
  end

  defp restore_ephemeral_entry(state, %{
         issue_id: issue_id,
         kind: kind,
         expires_at_ms: expires_at_ms
       })
       when is_binary(issue_id) and is_integer(expires_at_ms) do
    case normalize_ephemeral_kind(kind) do
      :claimed ->
        %{
          state
          | claimed: MapSet.put(state.claimed, issue_id),
            claimed_until: Map.put(state.claimed_until, issue_id, expires_at_ms)
        }

      :completed ->
        %{
          state
          | completed: MapSet.put(state.completed, issue_id),
            completed_until: Map.put(state.completed_until, issue_id, expires_at_ms)
        }
    end
  end

  defp restore_ephemeral_entry(state, _entry), do: state

  defp restore_persisted_retries(%__MODULE__{retry_store: nil} = state), do: state

  defp restore_persisted_retries(state) do
    case state.retry_store.list() do
      {:ok, retry_entries} ->
        now_ms = System.monotonic_time(:millisecond)

        Enum.reduce(retry_entries, state, fn retry_entry, acc ->
          restore_retry_entry(acc, retry_entry, now_ms)
        end)

      {:error, reason} ->
        Logger.warning("Failed to restore persisted retries: #{reason}")
        state
    end
  rescue
    error ->
      Logger.warning("Failed to restore persisted retries: #{Exception.message(error)}")
      state
  end

  defp restore_retry_entry(state, retry_entry, now_ms) when is_map(retry_entry) do
    issue_id =
      retry_entry
      |> field(:issue_id)
      |> case do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end

    if is_nil(issue_id) do
      state
    else
      delay_ms = max(Map.get(retry_entry, :due_at_ms, now_ms) - now_ms, 0)
      timer_ref = Process.send_after(self(), {:retry_due, issue_id}, delay_ms)

      restored_entry =
        retry_entry
        |> Map.put(:kind, retry_kind(retry_entry))
        |> Map.put(:timer_ref, timer_ref)
        |> Map.put_new(:finalization, %{})

      state
      |> then(fn acc ->
        %{acc | retry_attempts: Map.put(acc.retry_attempts, issue_id, restored_entry)}
      end)
      |> claim_with_expiry(issue_id, claim_expiry_from_retry(state, retry_entry, now_ms))
    end
  end

  defp restore_retry_entry(state, _retry_entry, _now_ms), do: state

  defp claim_expiry_from_retry(state, retry_entry, now_ms) do
    base_expiry = now_ms + state.claim_ttl_ms
    retry_due_ms = Map.get(retry_entry, :due_at_ms, now_ms)

    max(base_expiry, retry_due_ms + state.claim_ttl_ms)
  end

  defp list_agent_pool_children(agent_pool) do
    {:ok, DynamicSupervisor.which_children(agent_pool)}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp worker_child_pids(children) do
    Enum.flat_map(children, fn
      {_id, pid, :worker, _modules} when is_pid(pid) -> [pid]
      _other -> []
    end)
  end

  defp maybe_sync_managed_repos(state) do
    now_ms = System.monotonic_time(:millisecond)

    if repo_sync_due?(state, now_ms) and not repo_sync_in_progress?(state) do
      state
      |> start_repo_sync_task(now_ms)
      |> Map.put(:last_repo_sync_at_ms, now_ms)
    else
      state
    end
  end

  defp repo_sync_due?(state, now_ms) do
    interval_ms = state.repo_sync_interval_ms

    case state.last_repo_sync_at_ms do
      nil ->
        true

      last_sync_ms when is_integer(last_sync_ms) ->
        now_ms - last_sync_ms >= interval_ms

      _other ->
        true
    end
  end

  defp start_repo_sync_task(state, started_at_ms) do
    orchestrator_pid = self()
    repo_syncer = state.repo_syncer
    repo_local_path = state.repo_local_path
    repo_default_branch = state.repo_default_branch

    {repo_sync_pid, repo_sync_ref} =
      spawn_monitor(fn ->
        result = sync_managed_repos(repo_syncer, repo_local_path, repo_default_branch)
        send(orchestrator_pid, {:repo_sync_result, self(), result})
      end)

    timeout_ref =
      Process.send_after(
        self(),
        {:repo_sync_timeout, repo_sync_ref, repo_sync_pid},
        state.repo_sync_timeout_ms
      )

    %{
      state
      | repo_sync_task_ref: repo_sync_ref,
        repo_sync_task_pid: repo_sync_pid,
        repo_sync_timeout_timer_ref: timeout_ref,
        repo_sync_started_at_ms: started_at_ms
    }
  end

  defp repo_sync_in_progress?(state), do: is_reference(state.repo_sync_task_ref)

  defp clear_repo_sync_task_state(state) do
    if is_reference(state.repo_sync_timeout_timer_ref) do
      Process.cancel_timer(state.repo_sync_timeout_timer_ref)
    end

    if is_reference(state.repo_sync_task_ref) do
      Process.demonitor(state.repo_sync_task_ref, [:flush])
    end

    %{
      state
      | repo_sync_task_ref: nil,
        repo_sync_task_pid: nil,
        repo_sync_timeout_timer_ref: nil,
        repo_sync_started_at_ms: nil
    }
  end

  defp sync_managed_repos(nil, repo_local_path, repo_default_branch) do
    sync_repo(repo_local_path, repo_default_branch)
  end

  defp sync_managed_repos(repo_syncer, _repo_local_path, _repo_default_branch) do
    invoke_repo_syncer(repo_syncer)
  end

  defp invoke_repo_syncer(repo_syncer) when is_function(repo_syncer, 0) do
    normalize_sync_result(repo_syncer.())
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp invoke_repo_syncer(repo_syncer) when is_atom(repo_syncer) do
    case Code.ensure_loaded(repo_syncer) do
      {:module, _module} ->
        if function_exported?(repo_syncer, :sync_enabled_projects, 0) do
          normalize_sync_result(repo_syncer.sync_enabled_projects())
        else
          {:error, "repo syncer #{inspect(repo_syncer)} does not export sync_enabled_projects/0"}
        end

      {:error, reason} ->
        {:error, "repo syncer #{inspect(repo_syncer)} could not be loaded: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp invoke_repo_syncer(_repo_syncer), do: {:error, "invalid repo syncer"}

  defp normalize_sync_result(:ok), do: :ok
  defp normalize_sync_result({:ok, _value}), do: :ok
  defp normalize_sync_result({:error, _reason} = error), do: error
  defp normalize_sync_result(other), do: {:error, "unexpected sync result: #{inspect(other)}"}

  defp sync_repo(nil, _branch), do: :ok

  defp sync_repo(local_path, branch) do
    case RepoSync.sync(local_path, branch) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, to_string(reason)}

      other ->
        {:error, "unexpected repo sync result: #{inspect(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
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

  defp tracker_mark_done(state, issue_id, done_metadata, run_entry) when is_map(done_metadata) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <- tracker_call(tracker, :mark_done, [config, issue_id, done_metadata]) do
      state = release_claim(state, issue_id)
      {:ok, maybe_cleanup_terminal_workspace(state, run_entry, config)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp maybe_tracker_mark_merged(state, issue_id, issue, mark_merged?, done_metadata)
       when is_boolean(mark_merged?) and is_map(done_metadata) do
    if mark_merged? do
      tracker_mark_merged(state, issue_id, issue, done_metadata)
    else
      {:ok, state}
    end
  end

  defp tracker_mark_merged(state, issue_id, issue, done_metadata) when is_map(done_metadata) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <- tracker_call(tracker, :mark_merged, [config, issue_id, done_metadata]) do
      identifier = issue_identifier(issue)
      {:ok, cleanup_workspace_for_terminal_issue(state, config, issue_id, identifier)}
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

  defp tracker_mark_resumable(state, issue_id, done_metadata) when is_map(done_metadata) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <- tracker_call(tracker, :mark_resumable, [config, issue_id, done_metadata]) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp tracker_mark_pending_merge(state, issue_id, pending_merge_metadata)
       when is_map(pending_merge_metadata) do
    with {:ok, config} <- fetch_config(state.workflow_store),
         tracker <- resolve_tracker(state.tracker, config),
         :ok <-
           tracker_call(tracker, :mark_pending_merge, [config, issue_id, pending_merge_metadata]) do
      {:ok, release_claim(state, issue_id)}
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

  defp publish_merged?(%Result{} = result) do
    Enum.any?(result.events || [], fn event ->
      type = Map.get(event, :type) || Map.get(event, "type")
      type in [:publish_merged, "publish_merged"]
    end)
  end

  defp publish_pending_merge?(%Result{} = result) do
    Enum.any?(result.events || [], fn event ->
      type = Map.get(event, :type) || Map.get(event, "type")
      type in [:publish_pr_created, "publish_pr_created"]
    end)
  end

  defp successful_run_retry_payload(
         done_metadata,
         _mark_merged?,
         true,
         result,
         _run_entry
       ) do
    {
      :finalize_pending_merge,
      %{pending_merge_metadata: pending_merge_metadata(result, done_metadata)}
    }
  end

  defp successful_run_retry_payload(
         done_metadata,
         mark_merged?,
         _mark_pending_merge?,
         _result,
         run_entry
       ) do
    {
      :finalize_done,
      %{
        done_metadata: done_metadata,
        mark_merged?: mark_merged?,
        run_entry: retry_run_entry(run_entry)
      }
    }
  end

  defp finalize_pending_merge_run(state, issue_id, pending_merge_metadata)
       when is_map(pending_merge_metadata) do
    tracker_mark_pending_merge(state, issue_id, pending_merge_metadata)
  end

  defp pending_merge_metadata(%Result{} = result, done_metadata) when is_map(done_metadata) do
    done_metadata
    |> maybe_put_pending_value(
      :pr_url,
      event_field(result, [:publish_pr_created, "publish_pr_created"], :pr_url)
    )
    |> maybe_put_pending_value(
      :merge_failed_reason,
      event_field(result, [:publish_merge_failed, "publish_merge_failed"], :reason)
    )
  end

  defp event_field(%Result{} = result, event_types, field_name)
       when is_list(event_types) and is_atom(field_name) do
    result.events
    |> List.wrap()
    |> Enum.find_value(fn event ->
      type = Map.get(event, :type) || Map.get(event, "type")

      if type in event_types do
        Map.get(event, field_name) || Map.get(event, Atom.to_string(field_name))
      else
        nil
      end
    end)
  end

  defp maybe_put_pending_value(metadata, _key, nil) when is_map(metadata), do: metadata

  defp maybe_put_pending_value(metadata, key, value) when is_map(metadata) and is_atom(key) do
    Map.put(metadata, key, value)
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

  defp prepare_run_log_context(config, issue, attempt, opts) do
    case RunLogs.prepare_attempt(config, issue, attempt, opts) do
      {:ok, context} ->
        context

      {:error, reason} ->
        Logger.warning(
          "Failed to initialize run logs issue_id=#{issue_id(issue) || "-"} identifier=#{issue_identifier(issue) || "-"}: #{reason}"
        )

        nil
    end
  end

  defp maybe_put_prompt_template(run_opts, workflow_store) when is_list(run_opts) do
    case prompt_template_from_workflow_store(workflow_store) do
      template when is_binary(template) and template != "" ->
        Keyword.put(run_opts, :prompt_template, template)

      _other ->
        run_opts
    end
  end

  defp prompt_template_from_workflow_store(%Config{}), do: nil

  defp prompt_template_from_workflow_store(workflow_store) do
    WorkflowStore.get_prompt_template(workflow_store)
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
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
    runtime = get_in(config, [Access.key(:runtime, %{})]) || %{}

    processes =
      runtime
      |> Map.get(:processes, Map.get(runtime, "processes", []))
      |> case do
        value when is_list(value) ->
          value
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        _other ->
          []
      end

    if processes == [], do: :checks_only, else: :full_stack
  end

  defp initial_runtime_process_state(:full_stack), do: :pending
  defp initial_runtime_process_state(_profile), do: :not_required

  defp apply_runtime_limits(state, config) do
    poll_interval_ms =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:interval_ms)]),
        state.poll_interval_ms
      )

    repo_sync_interval_ms =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:repo_sync_interval_ms)]),
        state.repo_sync_interval_ms
      )

    repo_sync_timeout_ms =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:repo_sync_timeout_ms)]),
        state.repo_sync_timeout_ms
      )

    requested_max_concurrent_agents =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:max_concurrent_agents)]),
        state.requested_max_concurrent_agents
      )

    max_concurrent_agents =
      clamp_max_concurrent_agents(
        requested_max_concurrent_agents,
        state.global_max_concurrent_agents
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

    claim_ttl_ms =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:claim_ttl_ms)]),
        state.claim_ttl_ms
      )

    completed_ttl_ms =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:completed_ttl_ms)]),
        state.completed_ttl_ms
      )

    run_timeout_ms =
      positive_integer(
        get_in(config, [Access.key(:agent, %{}), Access.key(:run_timeout_ms)]),
        state.run_timeout_ms
      )

    stale_threshold_multiplier =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:stale_threshold_multiplier)]),
        state.stale_threshold_multiplier
      )

    watchdog_check_interval_ms =
      positive_integer(
        get_in(config, [Access.key(:polling, %{}), Access.key(:watchdog_check_interval_ms)]),
        state.watchdog_check_interval_ms
      )

    %{
      state
      | poll_interval_ms: poll_interval_ms,
        repo_sync_interval_ms: repo_sync_interval_ms,
        repo_sync_timeout_ms: repo_sync_timeout_ms,
        requested_max_concurrent_agents: requested_max_concurrent_agents,
        max_concurrent_agents: max_concurrent_agents,
        max_retry_backoff_ms: max_retry_backoff_ms,
        retries_enabled: retries_enabled,
        max_attempts: max_attempts,
        claim_ttl_ms: claim_ttl_ms,
        completed_ttl_ms: completed_ttl_ms,
        run_timeout_ms: run_timeout_ms,
        stale_threshold_multiplier: stale_threshold_multiplier,
        watchdog_check_interval_ms: watchdog_check_interval_ms
    }
  end

  defp refresh_project_limits(state) do
    %{
      state
      | project_max_concurrent_agents: normalize_project_limits(fetch_project_limits(state))
    }
  end

  defp fetch_project_limits(state) do
    case state.project_limit_fetcher do
      fetcher when is_function(fetcher, 0) ->
        fetcher.()

      fetcher when is_atom(fetcher) ->
        if function_exported?(fetcher, :project_max_concurrent_agents, 0) do
          fetcher.project_max_concurrent_agents()
        else
          %{}
        end

      _other ->
        %{}
    end
  rescue
    error ->
      Logger.warning("failed to refresh project concurrency limits: #{Exception.message(error)}")
      %{}
  catch
    :exit, reason ->
      Logger.warning("failed to refresh project concurrency limits: #{inspect(reason)}")
      %{}
  end

  defp default_project_limit_fetcher, do: %{}

  defp normalize_project_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {project_key, value}, acc ->
      project_slug = optional_trimmed_string(project_key)
      limit = positive_integer(value, nil)

      if is_binary(project_slug) and is_integer(limit) do
        Map.put(acc, project_slug, limit)
      else
        acc
      end
    end)
  end

  defp normalize_project_limits(limits) when is_list(limits) do
    Enum.reduce(limits, %{}, fn item, acc ->
      case item do
        {project_key, value} ->
          normalize_project_limits(Map.put(acc, project_key, value))

        %{project_slug: project_key, max_concurrent_agents: value} ->
          normalize_project_limits(Map.put(acc, project_key, value))

        _other ->
          acc
      end
    end)
  end

  defp normalize_project_limits(_limits), do: %{}

  defp issue_project_key(issue, config) do
    issue_project_slug =
      issue
      |> field(:project_slug)
      |> optional_trimmed_string()

    config_project_slug =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:project_slug)])
      |> optional_trimmed_string()

    issue_project_slug || config_project_slug || "default"
  end

  defp configured_project_max_concurrent_agents(state, issue, config) do
    project_key = issue_project_key(issue, config)

    workflow_project_limits =
      get_in(config, [Access.key(:agent, %{}), Access.key(:project_max_concurrent_agents)]) || %{}

    Map.get(workflow_project_limits, project_key) ||
      Map.get(state.project_max_concurrent_agents, project_key)
  end

  defp effective_project_max_concurrent_agents(state, issue, config) do
    configured_limit = configured_project_max_concurrent_agents(state, issue, config)

    case positive_integer(configured_limit, state.max_concurrent_agents) do
      value when is_integer(value) and value > 0 -> min(value, state.max_concurrent_agents)
      _other -> state.max_concurrent_agents
    end
  end

  defp running_counts_by_project(state, config) do
    Enum.reduce(state.running, %{}, fn {_issue_id, run_entry}, acc ->
      project_key = issue_project_key(Map.get(run_entry, :issue, %{}), config)
      Map.update(acc, project_key, 1, &(&1 + 1))
    end)
  end

  defp retry_counts_by_project(state, config) do
    Enum.reduce(state.retry_attempts, %{}, fn {_issue_id, retry_entry}, acc ->
      project_key = issue_project_key(Map.get(retry_entry, :issue, %{}), config)
      Map.update(acc, project_key, 1, &(&1 + 1))
    end)
  end

  defp project_running_count(state, issue, config) do
    project_key = issue_project_key(issue, config)

    state.running
    |> Enum.count(fn {_issue_id, run_entry} ->
      issue_project_key(Map.get(run_entry, :issue, %{}), config) == project_key
    end)
  end

  defp optional_trimmed_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_trimmed_string(value) when is_atom(value) do
    value |> Atom.to_string() |> optional_trimmed_string()
  end

  defp optional_trimmed_string(_value), do: nil

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
    do:
      state_name
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[\s-]+/u, "_")

  defp issue_id(issue) do
    value = field(issue, :id)
    if non_empty_string?(value), do: value, else: nil
  end

  defp issue_identifier(issue) do
    value = field(issue, :identifier)
    if non_empty_string?(value), do: value, else: nil
  end

  defp issue_pr_url(issue) do
    value = field(issue, :pr_url)
    if non_empty_string?(value), do: value, else: nil
  end

  defp find_issue(issues, issue_id) do
    Enum.find(issues, fn issue -> issue_id(issue) == issue_id end)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp list_value(value) when is_list(value), do: value
  defp list_value(_value), do: []

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp normalize_maintenance_mode(:normal), do: :normal
  defp normalize_maintenance_mode(:drain), do: :drain
  defp normalize_maintenance_mode("normal"), do: :normal
  defp normalize_maintenance_mode("drain"), do: :drain

  defp normalize_maintenance_mode(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> normalize_maintenance_mode()
  end

  defp normalize_maintenance_mode(_value), do: :invalid

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

  defp positive_integer_with_default(nil, default, _field), do: default

  defp positive_integer_with_default(value, default, field) do
    case positive_integer(value, nil) do
      int when is_integer(int) and int > 0 ->
        int

      _other ->
        Logger.warning("Invalid #{field}=#{inspect(value)}; using #{default}")
        default
    end
  end

  defp clamp_max_concurrent_agents(requested_max, hard_cap)
       when is_integer(requested_max) and requested_max > 0 and is_integer(hard_cap) and
              hard_cap > 0,
       do: min(requested_max, hard_cap)

  defp clamp_max_concurrent_agents(requested_max, _hard_cap)
       when is_integer(requested_max) and requested_max > 0,
       do: requested_max

  defp clamp_max_concurrent_agents(_requested_max, hard_cap)
       when is_integer(hard_cap) and hard_cap > 0,
       do: hard_cap

  defp clamp_max_concurrent_agents(_requested_max, _hard_cap), do: @default_max_concurrent_agents

  defp schedule_poll(state, delay_ms) do
    if state.poll_timer_ref do
      Process.cancel_timer(state.poll_timer_ref)
    end

    ref = Process.send_after(self(), :poll, delay_ms)
    %{state | poll_timer_ref: ref}
  end

  defp schedule_watchdog_tick(state, delay_ms) do
    if state.watchdog_timer_ref do
      Process.cancel_timer(state.watchdog_timer_ref)
    end

    ref = Process.send_after(self(), :watchdog_tick, delay_ms)
    %{state | watchdog_timer_ref: ref}
  end

  defp schedule_status_tick(state, delay_ms) do
    if state.status_tick_timer_ref do
      Process.cancel_timer(state.status_tick_timer_ref)
    end

    ref = Process.send_after(self(), :status_tick, delay_ms)
    %{state | status_tick_timer_ref: ref}
  end

  defp refresh_maintenance_mode(state) do
    mode = ControlState.load_maintenance_mode(state.maintenance_mode)

    if mode == state.maintenance_mode do
      state
    else
      Logger.info("orchestrator_event=maintenance_mode_changed mode=#{mode}")
      set_maintenance_mode_state(state, mode, persist?: false, source: :control_file)
    end
  end

  defp set_maintenance_mode_state(state, mode, opts) do
    persist? = Keyword.get(opts, :persist?, true)
    source = Keyword.get(opts, :source, :unknown)
    mode = normalize_maintenance_mode(mode)

    if mode == :invalid do
      state
    else
      if persist? do
        case ControlState.write_maintenance_mode(mode, source: source) do
          :ok -> :ok
          {:error, reason} -> Logger.warning("Failed to persist maintenance mode: #{reason}")
        end
      end

      state = %{state | maintenance_mode: mode}

      if mode == :normal and state.auto_poll do
        schedule_poll(state, 0)
      else
        state
      end
    end
  end

  defp persist_control_status(state) do
    status = status_snapshot(state)

    case ControlState.write_status(status) do
      :ok ->
        state

      {:error, reason} ->
        Logger.warning("Failed to persist orchestrator status snapshot: #{reason}")
        state
    end
  end

  defp run_poll_watchdog(state) do
    age_ms = poll_age_ms(state)
    threshold_ms = stale_threshold_ms(state)
    stale? = stale_poll?(age_ms, threshold_ms)

    cond do
      not stale? ->
        maybe_clear_stale_state(state, age_ms, threshold_ms)

      state.poll_stale_recovery_attempted ->
        diagnostics = stale_diagnostics(state, age_ms, threshold_ms)

        Logger.error(
          "orchestrator_event=poll_watchdog_restart reason=persistent_stale diagnostics=#{inspect(diagnostics)}"
        )

        exit({:poll_watchdog_stale, diagnostics})

      true ->
        state =
          if state.poll_stale do
            state
          else
            Logger.warning(
              "orchestrator_event=poll_watchdog_stale_detected diagnostics=#{inspect(stale_diagnostics(state, age_ms, threshold_ms))}"
            )

            %{state | poll_stale: true, poll_stale_detected_at: now()}
          end

        run_watchdog_recovery_poll(state, age_ms, threshold_ms)
    end
  end

  defp run_watchdog_recovery_poll(state, age_ms, threshold_ms) do
    attempted_at = now()

    Logger.warning(
      "orchestrator_event=poll_watchdog_recovery_attempt diagnostics=#{inspect(stale_diagnostics(state, age_ms, threshold_ms))}"
    )

    state =
      state
      |> Map.put(:poll_stale_recovery_attempted, true)
      |> run_poll_cycle()
      |> maybe_reschedule_poll_after_watchdog_recovery()

    post_recovery_age_ms = poll_age_ms(state)
    still_stale? = stale_poll?(post_recovery_age_ms, threshold_ms)

    outcome = if still_stale?, do: :still_stale, else: :recovered

    state =
      Map.put(state, :last_recovery_attempt, %{
        attempted_at: attempted_at,
        stale_age_ms: age_ms,
        threshold_ms: threshold_ms,
        post_recovery_age_ms: post_recovery_age_ms,
        outcome: outcome
      })

    if still_stale? do
      state
    else
      Logger.info(
        "orchestrator_event=poll_watchdog_recovery_succeeded diagnostics=#{inspect(stale_diagnostics(state, post_recovery_age_ms, threshold_ms))}"
      )

      %{
        state
        | poll_stale: false,
          poll_stale_detected_at: nil,
          poll_stale_recovery_attempted: false
      }
    end
  end

  defp maybe_reschedule_poll_after_watchdog_recovery(state) do
    if state.auto_poll do
      schedule_poll(state, state.poll_interval_ms)
    else
      state
    end
  end

  defp maybe_clear_stale_state(state, age_ms, threshold_ms) do
    if state.poll_stale do
      Logger.info(
        "orchestrator_event=poll_watchdog_stale_cleared diagnostics=#{inspect(stale_diagnostics(state, age_ms, threshold_ms))}"
      )

      %{
        state
        | poll_stale: false,
          poll_stale_detected_at: nil,
          poll_stale_recovery_attempted: false
      }
    else
      state
    end
  end

  defp stale_diagnostics(state, age_ms, threshold_ms) do
    %{
      stale: stale_poll?(age_ms, threshold_ms),
      age_ms: age_ms,
      threshold_ms: threshold_ms,
      poll_interval_ms: state.poll_interval_ms,
      stale_threshold_multiplier: state.stale_threshold_multiplier,
      last_poll_at: state.last_poll_at,
      stale_detected_at: state.poll_stale_detected_at,
      recovery_attempted: state.poll_stale_recovery_attempted
    }
  end

  defp status_snapshot(state) do
    now_ms = System.monotonic_time(:millisecond)
    poll_age_ms = poll_age_ms(state, now_ms)
    stale_threshold_ms = stale_threshold_ms(state)
    poll_stale = stale_poll?(poll_age_ms, stale_threshold_ms)

    running =
      state.running
      |> Enum.map(fn {issue_id, entry} ->
        runtime_last_event = Map.get(entry, :runtime_last_event)

        %{
          issue_id: issue_id,
          identifier: issue_identifier(entry.issue),
          attempt: entry.attempt,
          started_at: entry.started_at,
          retry_mode: normalize_retry_mode(Map.get(entry, :retry_mode, :full_rerun)),
          retry_provenance: normalize_retry_provenance(Map.get(entry, :retry_provenance, %{})),
          run_phase: Map.get(entry, :run_phase, RunPhase.unknown()),
          run_phase_label: entry |> Map.get(:run_phase) |> RunPhase.label(),
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
          kind: retry_kind(entry),
          reason: entry.reason,
          due_in_ms: retry_due_in_ms(entry, now_ms)
        }
      end)
      |> Enum.sort_by(& &1.issue_id)

    running_count = map_size(state.running)
    project_limits = project_limits_snapshot(state)

    %{
      running: running,
      retrying: retrying,
      running_count: running_count,
      retry_count: map_size(state.retry_attempts),
      claimed_count: MapSet.size(state.claimed),
      claimed_issue_ids: state.claimed |> MapSet.to_list() |> Enum.sort(),
      completed_count: MapSet.size(state.completed),
      maintenance_mode: state.maintenance_mode,
      dispatch_paused: state.maintenance_mode == :drain,
      drain_ready: running_count == 0,
      control_paths: %{
        maintenance_mode: ControlState.maintenance_mode_path(),
        status: ControlState.status_path()
      },
      poll_interval_ms: state.poll_interval_ms,
      repo_sync_interval_ms: state.repo_sync_interval_ms,
      repo_sync_timeout_ms: state.repo_sync_timeout_ms,
      repo_sync_due_in_ms: repo_sync_due_in_ms(state, now_ms),
      repo_sync_in_progress: repo_sync_in_progress?(state),
      max_concurrent_agents_requested: state.requested_max_concurrent_agents,
      max_concurrent_agents_effective: state.max_concurrent_agents,
      max_concurrent_agents_hard_cap: state.global_max_concurrent_agents,
      max_concurrent_agents: state.max_concurrent_agents,
      project_limits: project_limits,
      retries_enabled: state.retries_enabled,
      max_attempts: state.max_attempts,
      max_retry_backoff_ms: state.max_retry_backoff_ms,
      retry_base_delay_ms: state.retry_base_delay_ms,
      continuation_delay_ms: state.continuation_delay_ms,
      claim_ttl_ms: state.claim_ttl_ms,
      completed_ttl_ms: state.completed_ttl_ms,
      run_timeout_ms: state.run_timeout_ms,
      last_error: state.last_error,
      last_poll_at: state.last_poll_at,
      watchdog: %{
        stale: poll_stale,
        age_ms: poll_age_ms,
        threshold_ms: stale_threshold_ms,
        stale_threshold_multiplier: state.stale_threshold_multiplier,
        check_interval_ms: state.watchdog_check_interval_ms,
        stale_detected_at: state.poll_stale_detected_at,
        recovery_attempted: state.poll_stale_recovery_attempted,
        last_recovery_attempt: state.last_recovery_attempt
      }
    }
  end

  defp project_limits_snapshot(state) do
    with {:ok, config} <- fetch_config(state.workflow_store) do
      running_counts = running_counts_by_project(state, config)
      retry_counts = retry_counts_by_project(state, config)

      configured_project_keys =
        Map.keys(state.project_max_concurrent_agents) ++
          Map.keys(
            get_in(config, [Access.key(:agent, %{}), Access.key(:project_max_concurrent_agents)]) ||
              %{}
          )

      active_project_keys = Map.keys(running_counts) ++ Map.keys(retry_counts)

      (configured_project_keys ++ active_project_keys)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn project_key ->
        representative_issue = %{project_slug: project_key}

        configured_limit =
          configured_project_max_concurrent_agents(state, representative_issue, config)

        effective_limit =
          effective_project_max_concurrent_agents(state, representative_issue, config)

        running_count = Map.get(running_counts, project_key, 0)
        retry_count = Map.get(retry_counts, project_key, 0)

        %{
          project_slug: project_key,
          configured_max_concurrent_agents: configured_limit,
          effective_max_concurrent_agents: effective_limit,
          running_count: running_count,
          retry_count: retry_count,
          available_slots: max(effective_limit - running_count, 0)
        }
      end)
    else
      _ -> []
    end
  end

  defp runtime_last_event_type(%{} = event), do: Map.get(event, :type)
  defp runtime_last_event_type(_event), do: nil

  defp runtime_last_event_at(%{} = event), do: Map.get(event, :timestamp)
  defp runtime_last_event_at(_event), do: nil

  defp retry_due_in_ms(entry, now_ms) when is_map(entry) and is_integer(now_ms) do
    case Map.get(entry, :due_at_ms) do
      due_at_ms when is_integer(due_at_ms) ->
        max(due_at_ms - now_ms, 0)

      _other ->
        0
    end
  end

  defp retry_due_in_ms(_entry, _now_ms), do: 0

  defp repo_sync_due_in_ms(state, now_ms) do
    case state.last_repo_sync_at_ms do
      nil ->
        0

      last_sync_ms when is_integer(last_sync_ms) ->
        max(state.repo_sync_interval_ms - (now_ms - last_sync_ms), 0)

      _other ->
        0
    end
  end

  defp record_poll_heartbeat(state) do
    %{state | last_poll_at: now(), last_poll_monotonic_ms: monotonic_now_ms()}
  end

  defp stale_threshold_ms(state) do
    state.poll_interval_ms * state.stale_threshold_multiplier
  end

  defp poll_age_ms(state, now_ms \\ monotonic_now_ms()) do
    case state.last_poll_monotonic_ms do
      last_ms when is_integer(last_ms) and is_integer(now_ms) ->
        max(now_ms - last_ms, 0)

      _other ->
        nil
    end
  end

  defp stale_poll?(age_ms, threshold_ms)
       when is_integer(age_ms) and is_integer(threshold_ms) and threshold_ms > 0,
       do: age_ms >= threshold_ms

  defp stale_poll?(_age_ms, _threshold_ms), do: false

  defp monotonic_now_ms, do: System.monotonic_time(:millisecond)

  defp cleanup_preview_for_issue(config, issue_id) when is_binary(issue_id) do
    project_slug =
      config
      |> get_in([Access.key(:tracker, %{}), Access.key(:project_slug)])
      |> optional_trimmed_string()
      |> Kernel.||("default")

    Kollywood.PreviewSessionManager.stop_if_active(project_slug, issue_id)
  rescue
    _ -> :ok
  end

  defp cleanup_preview_for_issue(_config, _issue_id), do: :ok

  defp maybe_cleanup_terminal_workspace(state, run_entry, config) do
    issue_id = run_entry_issue_id(run_entry)
    identifier = run_entry_identifier(run_entry)
    cleanup_workspace_for_terminal_issue(state, config, issue_id, identifier, run_entry)
  end

  defp cleanup_workspace_for_terminal_issue(state, config, issue_id, identifier) do
    cleanup_workspace_for_terminal_issue(state, config, issue_id, identifier, nil)
  end

  defp cleanup_workspace_for_terminal_issue(state, config, issue_id, identifier, run_entry) do
    cleanup_preview_for_issue(config, issue_id)

    if non_empty_string?(identifier) do
      hooks = Map.get(config, :hooks, %{})

      case Workspace.cleanup_for_issue(identifier, config, hooks) do
        :ok ->
          maybe_record_workspace_cleanup(state, identifier, run_entry, :deleted)

        {:error, reason} ->
          Logger.warning(
            "Failed to cleanup workspace for terminal issue issue_id=#{issue_id || "-"} identifier=#{identifier}: #{reason}"
          )

          maybe_record_workspace_cleanup(state, identifier, run_entry, :preserved, reason)
      end
    else
      Logger.warning(
        "Skipping workspace cleanup for terminal issue_id=#{issue_id || "-"}: identifier unavailable"
      )

      state
    end
  end

  defp maybe_record_workspace_cleanup(state, identifier, run_entry, action, reason \\ nil) do
    payload = workspace_cleanup_payload(state, identifier, action, reason)

    event_type =
      if action == :deleted, do: :workspace_cleanup_deleted, else: :workspace_cleanup_preserved

    maybe_persist_workspace_cleanup_event(run_entry, Map.put(payload, :type, event_type))
    state
  end

  defp workspace_cleanup_payload(state, identifier, action, reason) do
    workspace_config =
      case fetch_config(state.workflow_store) do
        {:ok, config} -> Map.get(config, :workspace, %{})
        _other -> %{}
      end

    workspace_root =
      workspace_config
      |> Map.get(:root, Kollywood.ServiceConfig.workspaces_dir())
      |> to_string()
      |> String.replace_prefix("~", System.user_home!())
      |> Path.expand()

    workspace_path = Path.join(workspace_root, Workspace.sanitize_key(identifier))

    case action do
      :deleted ->
        %{workspace_path: workspace_path, action: :deleted, identifier: identifier}

      :preserved ->
        %{
          workspace_path: workspace_path,
          action: :preserved,
          reason: reason,
          identifier: identifier
        }
    end
  end

  defp maybe_persist_workspace_cleanup_event(run_entry, event)
       when is_map(run_entry) and is_map(event) do
    run_log_context = Map.get(run_entry, :run_log_context)

    persist_run_log_event(
      run_log_context,
      event
      |> Map.put_new(:issue_id, run_entry_issue_id(run_entry))
      |> Map.put_new(:identifier, run_entry_identifier(run_entry))
    )
  end

  defp maybe_persist_workspace_cleanup_event(_run_entry, _event), do: :ok

  defp run_entry_issue(run_entry) when is_map(run_entry), do: Map.get(run_entry, :issue)
  defp run_entry_issue(_run_entry), do: nil

  defp run_entry_identifier(run_entry), do: run_entry |> run_entry_issue() |> issue_identifier()

  defp run_entry_issue_id(run_entry) do
    run_entry
    |> run_entry_issue()
    |> issue_id()
  end

  defp now, do: DateTime.utc_now()
end
