defmodule Kollywood.OrchestratorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator
  alias Kollywood.WorkflowStore

  defmodule ResumableTracker do
    @behaviour Kollywood.Tracker

    def put_state(test_pid, issue) when is_pid(test_pid) and is_map(issue) do
      :persistent_term.put({__MODULE__, :state}, %{test_pid: test_pid, issue: issue})
    end

    def clear_state do
      :persistent_term.erase({__MODULE__, :state})
    end

    @impl true
    def list_active_issues(_config) do
      state = :persistent_term.get({__MODULE__, :state}, %{issue: nil})
      {:ok, List.wrap(state.issue)}
    end

    @impl true
    def claim_issue(_config, _issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, _issue_id), do: :ok

    @impl true
    def mark_resumable(_config, issue_id, metadata) do
      notify({:tracker_mark_resumable, issue_id, metadata})
      :ok
    end

    @impl true
    def mark_done(_config, issue_id, metadata) do
      notify({:tracker_mark_done, issue_id, metadata})
      :ok
    end

    @impl true
    def mark_pending_merge(%Config{} = config, issue_id, _metadata) do
      if pid = get_in(config, [Access.key(:tracker, %{}), Access.key(:test_pid)]) do
        send(pid, {:tracker_mark_pending_merge, issue_id})
      end

      :ok
    end

    @impl true
    def mark_merged(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_failed(_config, issue_id, reason, attempt) do
      notify({:tracker_mark_failed, issue_id, reason, attempt})
      :ok
    end

    defp notify(message) do
      case :persistent_term.get({__MODULE__, :state}, nil) do
        %{test_pid: test_pid} when is_pid(test_pid) -> send(test_pid, message)
        _other -> :ok
      end
    end
  end

  defmodule MergeTracker do
    @behaviour Kollywood.Tracker

    @impl true
    def list_active_issues(%Config{} = config) do
      {:ok, get_in(config, [Access.key(:tracker, %{}), Access.key(:test_issues, [])])}
    end

    @impl true
    def claim_issue(_config, _issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, _issue_id), do: :ok

    @impl true
    def mark_resumable(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_done(%Config{} = config, issue_id, _metadata) do
      if pid = get_in(config, [Access.key(:tracker, %{}), Access.key(:test_pid)]) do
        send(pid, {:tracker_mark_done, issue_id})
      end

      :ok
    end

    @impl true
    def mark_pending_merge(%Config{} = config, issue_id, _metadata) do
      if pid = get_in(config, [Access.key(:tracker, %{}), Access.key(:test_pid)]) do
        send(pid, {:tracker_mark_pending_merge, issue_id})
      end

      :ok
    end

    @impl true
    def mark_merged(%Config{} = config, issue_id, _metadata) do
      if pid = get_in(config, [Access.key(:tracker, %{}), Access.key(:test_pid)]) do
        send(pid, {:tracker_mark_merged, issue_id})
      end

      :ok
    end

    @impl true
    def mark_failed(_config, _issue_id, _reason, _attempt), do: :ok
  end

  defmodule FlakyMarkInProgressTracker do
    @behaviour Kollywood.Tracker
    @issue_id "ISS-7"
    @issue_identifier "ABC-7"
    @attempts_table :kollywood_orchestrator_mark_in_progress_attempts

    @impl true
    def list_active_issues(_config) do
      {:ok,
       [
         %{
           id: @issue_id,
           identifier: @issue_identifier,
           title: "Issue #{@issue_identifier}",
           description: "Test issue",
           state: "Todo",
           priority: 1,
           created_at: "2026-01-01T00:00:00Z",
           blocked_by: []
         }
       ]}
    end

    @impl true
    def claim_issue(_config, @issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, @issue_id) do
      attempts = :ets.update_counter(@attempts_table, @issue_id, {2, 1}, {@issue_id, 0})

      if attempts == 1 do
        {:error, "forced mark_in_progress failure"}
      else
        :ok
      end
    end

    @impl true
    def mark_resumable(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_done(_config, @issue_id, _metadata), do: :ok

    @impl true
    def mark_pending_merge(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_merged(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_failed(_config, @issue_id, _reason, _attempt), do: :ok
  end

  defmodule MergeDetectionTracker do
    @behaviour Kollywood.Tracker

    def put_state(test_pid, issues) when is_pid(test_pid) and is_list(issues) do
      :persistent_term.put({__MODULE__, :state}, %{test_pid: test_pid, issues: issues})
    end

    def clear_state do
      :persistent_term.erase({__MODULE__, :state})
    end

    @impl true
    def list_active_issues(_config) do
      state = :persistent_term.get({__MODULE__, :state}, %{issues: []})
      {:ok, state.issues}
    end

    @impl true
    def list_pending_merge_issues(_config) do
      state = :persistent_term.get({__MODULE__, :state}, %{issues: []})

      issues =
        Enum.filter(state.issues, fn issue ->
          issue[:state] == "pending_merge" and is_binary(issue[:pr_url]) and issue[:pr_url] != ""
        end)

      {:ok, issues}
    end

    @impl true
    def claim_issue(_config, _issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, _issue_id), do: :ok

    @impl true
    def mark_resumable(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_done(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_pending_merge(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_merged(_config, issue_id, _metadata) do
      state = :persistent_term.get({__MODULE__, :state}, %{issues: []})

      issues =
        Enum.map(state.issues, fn issue ->
          if issue[:id] == issue_id do
            %{issue | state: "merged"}
          else
            update_blockers(issue, issue_id)
          end
        end)

      :persistent_term.put({__MODULE__, :state}, %{state | issues: issues})

      if is_pid(state[:test_pid]) do
        send(state.test_pid, {:tracker_mark_merged, issue_id})
      end

      :ok
    end

    @impl true
    def mark_failed(_config, _issue_id, _reason, _attempt), do: :ok

    defp update_blockers(issue, merged_issue_id) do
      blockers = Map.get(issue, :blocked_by, [])

      updated_blockers =
        Enum.map(blockers, fn blocker ->
          if blocker[:id] == merged_issue_id do
            %{blocker | state: "merged"}
          else
            blocker
          end
        end)

      Map.put(issue, :blocked_by, updated_blockers)
    end
  end

  defmodule FlakyMarkDoneTracker do
    @behaviour Kollywood.Tracker

    def put_state(test_pid, issue) when is_pid(test_pid) and is_map(issue) do
      :persistent_term.put({__MODULE__, :state}, %{test_pid: test_pid, issue: issue, attempts: 0})
    end

    def clear_state do
      :persistent_term.erase({__MODULE__, :state})
    end

    @impl true
    def list_active_issues(_config) do
      state = :persistent_term.get({__MODULE__, :state}, %{issue: nil})
      {:ok, List.wrap(state.issue)}
    end

    @impl true
    def claim_issue(_config, _issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, _issue_id), do: :ok

    @impl true
    def mark_resumable(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_done(_config, issue_id, _metadata) do
      state = :persistent_term.get({__MODULE__, :state}, %{attempts: 0})
      attempts = state.attempts + 1
      :persistent_term.put({__MODULE__, :state}, %{state | attempts: attempts})

      notify({:tracker_mark_done_attempt, issue_id, attempts})

      if attempts == 1 do
        {:error, "forced mark_done failure"}
      else
        :ok
      end
    end

    @impl true
    def mark_pending_merge(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_merged(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_failed(_config, _issue_id, _reason, _attempt), do: :ok

    defp notify(message) do
      case :persistent_term.get({__MODULE__, :state}, nil) do
        %{test_pid: test_pid} when is_pid(test_pid) -> send(test_pid, message)
        _other -> :ok
      end
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_orchestrator_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "poll executes repo syncer callback when configured", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{})
    test_pid = self()

    repo_syncer = fn ->
      send(test_pid, :repo_sync_called)
      :ok
    end

    tracker = fn _config -> {:ok, []} end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         auto_poll: false,
         repo_syncer: repo_syncer}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive :repo_sync_called
  end

  test "poll throttles repo syncer by configured interval", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{})
    test_pid = self()

    repo_syncer = fn ->
      send(test_pid, :repo_sync_called)
      :ok
    end

    tracker = fn _config -> {:ok, []} end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         auto_poll: false,
         repo_syncer: repo_syncer,
         repo_sync_interval_ms: 60_000}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert :ok = Orchestrator.poll_now(orchestrator)

    assert_receive :repo_sync_called
    refute_receive :repo_sync_called, 100

    status = Orchestrator.status(orchestrator)
    assert status.repo_sync_interval_ms == 60_000
    assert status.repo_sync_due_in_ms > 0
  end

  test "repo sync timeout does not stall dispatch", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{})
    issue = issue("ISS-SYNC-TIMEOUT", "ABC-SYNC-TIMEOUT", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    repo_syncer = fn ->
      send(test_pid, :repo_sync_started)
      Process.sleep(200)
      :ok
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         repo_syncer: repo_syncer,
         repo_sync_timeout_ms: 40,
         retry_base_delay_ms: 20}
      )

    log =
      capture_log(fn ->
        assert :ok = Orchestrator.poll_now(orchestrator)
        assert_receive :repo_sync_started
        assert_receive {:runner_started, "ISS-SYNC-TIMEOUT"}
        Process.sleep(80)
      end)

    assert log =~ "Managed repo sync timed out"

    status = Orchestrator.status(orchestrator)
    assert status.repo_sync_in_progress == false

    assert :ok = Orchestrator.poll_now(orchestrator)
  end

  test "repo sync failure is contained and poll still dispatches", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{})
    issue = issue("ISS-SYNC-FAIL", "ABC-SYNC-FAIL", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    repo_syncer = fn ->
      send(test_pid, :repo_sync_attempted)
      {:error, "forced sync failure"}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         repo_syncer: repo_syncer,
         retry_base_delay_ms: 20}
      )

    log =
      capture_log(fn ->
        assert :ok = Orchestrator.poll_now(orchestrator)
        assert_receive :repo_sync_attempted
        assert_receive {:runner_started, "ISS-SYNC-FAIL"}
        Process.sleep(30)
      end)

    assert log =~ "Managed repo sync failed: forced sync failure"
  end

  test "dispatches issues by priority with bounded concurrency", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_concurrent_agents: 1})
    test_pid = self()

    issue_one = issue("ISS-1", "ABC-1", 1)
    issue_two = issue("ISS-2", "ABC-2", 2)
    issues_agent = start_agent!(fn -> [issue_two, issue_one] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      receive do
        {:complete_runner, ^issue_id, result} ->
          send(test_pid, {:runner_finished, issue_id})
          result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-1", first_runner_pid, nil}
    refute_receive {:runner_started, "ISS-2", _, _}, 100

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 1
    assert status.claimed_issue_ids == ["ISS-1"]

    first_runner_ref = Process.monitor(first_runner_pid)
    send(first_runner_pid, {:complete_runner, "ISS-1", {:ok, success_result(issue_one)}})
    assert_receive {:runner_finished, "ISS-1"}
    assert_receive {:DOWN, ^first_runner_ref, :process, ^first_runner_pid, reason}
    assert reason in [:normal, :noproc]

    # ensure the orchestrator handled the task result before dispatching next issue
    _ = :sys.get_state(orchestrator)

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-2", second_runner_pid, nil}

    send(second_runner_pid, {:complete_runner, "ISS-2", {:ok, success_result(issue_two)}})
    assert_receive {:runner_finished, "ISS-2"}
  end

  test "status shows runtime process state for running issues", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{runtime_profile: "full_stack"})
    issue = issue("ISS-RT", "ABC-RT", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      on_event = Keyword.fetch!(opts, :on_event)
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      on_event.(%{
        type: :runtime_starting,
        timestamp: DateTime.utc_now(),
        issue_id: issue_id,
        identifier: issue.identifier
      })

      on_event.(%{
        type: :runtime_started,
        timestamp: DateTime.utc_now(),
        issue_id: issue_id,
        identifier: issue.identifier
      })

      send(test_pid, {:runner_runtime_started, issue_id})

      receive do
        {:complete_runner, ^issue_id, result} ->
          result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-RT", runner_pid, nil}
    assert_receive {:runner_runtime_started, "ISS-RT"}

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 1

    [running_entry] = status.running
    assert running_entry.issue_id == "ISS-RT"
    assert running_entry.runtime_profile == :full_stack
    assert running_entry.runtime_process_state == :running
    assert running_entry.runtime_last_event_type == :runtime_started
    assert %DateTime{} = running_entry.runtime_last_event_at

    runner_ref = Process.monitor(runner_pid)
    send(runner_pid, {:complete_runner, "ISS-RT", {:ok, success_result(issue)}})
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:normal, :noproc]
  end

  test "ignores stale run_worker_result messages from another pid", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_concurrent_agents: 1})
    issue = issue("ISS-STALE", "ABC-STALE", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      receive do
        {:complete_runner, ^issue_id, result} ->
          result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-STALE", runner_pid, nil}

    send(orchestrator, {:run_worker_result, "ISS-STALE", self(), {:ok, success_result(issue)}})

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 1
    assert Enum.any?(status.running, &(&1.issue_id == "ISS-STALE"))

    runner_ref = Process.monitor(runner_pid)
    send(runner_pid, {:complete_runner, "ISS-STALE", {:ok, success_result(issue)}})
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:normal, :noproc]

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
  end

  test "startup reconciliation skips redispatch for in_progress issues", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        max_concurrent_agents: 2,
        tracker_active_states: ["open", "in_progress"],
        tracker_terminal_states: ["done", "failed", "cancelled"]
      })

    test_pid = self()

    in_progress_issue = %{issue("ISS-10", "ABC-10", 1) | state: "in_progress"}
    open_issue = %{issue("ISS-11", "ABC-11", 2) | state: "open"}
    issues_agent = start_agent!(fn -> [in_progress_issue, open_issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      receive do
        {:complete_runner, ^issue_id, result} ->
          send(test_pid, {:runner_finished, issue_id})
          result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-11", runner_pid, nil}
    refute_receive {:runner_started, "ISS-10", _, _}, 100

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 1
    assert status.claimed_issue_ids == ["ISS-10", "ISS-11"]

    send(runner_pid, {:complete_runner, "ISS-11", {:ok, success_result(open_issue)}})
    assert_receive {:runner_finished, "ISS-11"}

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.claimed_issue_ids == ["ISS-10"]
  end

  test "startup reconciliation failure does not crash orchestrator", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_concurrent_agents: 1})
    test_pid = self()
    open_issue = issue("ISS-12", "ABC-12", 1)
    calls_agent = start_agent!(fn -> 0 end)

    tracker = fn _config ->
      call_number = Agent.get_and_update(calls_agent, fn count -> {count + 1, count + 1} end)

      case call_number do
        1 -> {:error, "tracker unavailable during startup"}
        _ -> {:ok, [open_issue]}
      end
    end

    runner = fn issue, opts ->
      send(test_pid, {:runner_started, issue.id, self(), Keyword.get(opts, :attempt)})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert Process.alive?(orchestrator)

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-12", _runner_pid, nil}
  end

  test "persists worker/reviewer/check/runtime logs and metadata per attempt", %{root: root} do
    prd_path = Path.join(root, "prd.json")

    %{store: workflow_store} =
      start_workflow_store!(root, %{tracker_kind: "prd_json", tracker_path: prd_path})

    issue = issue("ISS-LOG", "US-LOG", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      on_event = Keyword.fetch!(opts, :on_event)
      send(test_pid, {:runner_started, issue.id, self(), Keyword.get(opts, :attempt)})

      on_event.(%{type: :turn_succeeded, turn: 1, duration_ms: 5, output: "worker-output"})
      on_event.(%{type: :review_passed, cycle: 1, output: "review-output"})

      on_event.(%{
        type: :check_passed,
        check_index: 1,
        command: "mix test",
        duration_ms: 3,
        output: "checks-output"
      })

      on_event.(%{type: :runtime_started, duration_ms: 7, output: "runtime-output"})

      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-LOG", runner_pid, nil}

    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:normal, :noproc]

    _ = :sys.get_state(orchestrator)

    attempt_dir = Path.join([root, ".kollywood", "run_logs", "US-LOG", "attempt-0001"])

    assert File.exists?(Path.join(attempt_dir, "worker.log"))
    assert File.exists?(Path.join(attempt_dir, "reviewer.log"))
    assert File.exists?(Path.join(attempt_dir, "checks.log"))
    assert File.exists?(Path.join(attempt_dir, "runtime.log"))
    assert File.exists?(Path.join(attempt_dir, "events.jsonl"))

    assert File.read!(Path.join(attempt_dir, "worker.log")) =~ "worker-output"
    assert File.read!(Path.join(attempt_dir, "reviewer.log")) =~ "review-output"
    assert File.read!(Path.join(attempt_dir, "checks.log")) =~ "checks-output"
    assert File.read!(Path.join(attempt_dir, "runtime.log")) =~ "runtime-output"

    metadata = read_json!(Path.join(attempt_dir, "metadata.json"))

    assert metadata["status"] == "ok"
    assert metadata["attempt"] == 1
    assert metadata["runner_attempt"] == nil
    assert metadata["turn_count"] == 1
    assert metadata["story_id"] == "US-LOG"
  end

  test "retries failed runs with backoff and increments attempt", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_retry_backoff_ms: 200})
    issue = issue("ISS-3", "ABC-3", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)
    runner_calls = start_agent!(fn -> 0 end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      call_number = Agent.get_and_update(runner_calls, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:runner_attempt, call_number, Keyword.get(opts, :attempt)})

      case call_number do
        1 -> {:error, failed_result(issue, "forced failure")}
        _ -> {:ok, success_result(issue)}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_attempt, 1, nil}
    assert_receive {:runner_attempt, 2, 1}, 1_000

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.completed_count == 1
  end

  test "times out stuck runs and retries with attempt metadata", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{max_retry_backoff_ms: 200, max_concurrent_agents: 1})

    issue = issue("ISS-TIMEOUT", "ABC-TIMEOUT", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)
    runner_calls = start_agent!(fn -> 0 end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      call_number = Agent.get_and_update(runner_calls, fn count -> {count + 1, count + 1} end)

      send(
        test_pid,
        {:runner_started, call_number, issue.id, self(), Keyword.get(opts, :attempt)}
      )

      case call_number do
        1 ->
          receive do
            {:complete_runner, result} -> result
          after
            5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
          end

        _ ->
          {:ok, success_result(issue)}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         run_timeout_ms: 30,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, 1, "ISS-TIMEOUT", first_runner_pid, nil}

    first_runner_ref = Process.monitor(first_runner_pid)
    assert_receive {:DOWN, ^first_runner_ref, :process, ^first_runner_pid, reason}, 1_000
    assert reason in [:shutdown, :killed, :noproc]

    assert_receive {:runner_started, 2, "ISS-TIMEOUT", _second_runner_pid, 1}, 1_000

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.retry_count == 0
    assert status.completed_count == 1
    assert status.run_timeout_ms == 30
  end

  test "releases claim when mark_in_progress fails and redispatches on next poll", %{root: root} do
    attempts_table = :kollywood_orchestrator_mark_in_progress_attempts

    if :ets.whereis(attempts_table) != :undefined do
      :ets.delete(attempts_table)
    end

    :ets.new(attempts_table, [:named_table, :set, :public])

    on_exit(fn ->
      if :ets.whereis(attempts_table) != :undefined do
        :ets.delete(attempts_table)
      end
    end)

    %{store: workflow_store} = start_workflow_store!(root, %{max_retry_backoff_ms: 60_000})
    test_pid = self()

    runner = fn issue, opts ->
      send(test_pid, {:runner_started, issue.id, self(), Keyword.get(opts, :attempt)})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: FlakyMarkInProgressTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 60_000}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    refute_receive {:runner_started, "ISS-7", _, _}, 100

    status = Orchestrator.status(orchestrator)
    assert status.claimed_issue_ids == []

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-7", runner_pid, nil}

    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:normal, :noproc]
  end

  test "retries done finalization without rerunning a successful worker", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_retry_backoff_ms: 200})
    issue = issue("ISS-FINALIZE", "ABC-FINALIZE", 1)
    test_pid = self()
    runner_calls = start_agent!(fn -> 0 end)

    FlakyMarkDoneTracker.put_state(test_pid, issue)
    on_exit(fn -> FlakyMarkDoneTracker.clear_state() end)

    runner = fn issue, opts ->
      Agent.update(runner_calls, &(&1 + 1))
      send(test_pid, {:runner_attempt, issue.id, Keyword.get(opts, :attempt)})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: FlakyMarkDoneTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_attempt, "ISS-FINALIZE", nil}
    assert_receive {:tracker_mark_done_attempt, "ISS-FINALIZE", 1}
    assert_receive {:tracker_mark_done_attempt, "ISS-FINALIZE", 2}, 1_000
    refute_receive {:runner_attempt, "ISS-FINALIZE", 1}, 150

    _ = :sys.get_state(orchestrator)

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.retry_count == 0
    assert status.completed_count == 1
    assert Agent.get(runner_calls, & &1) == 1
  end

  test "does not retry failed runs when retries are disabled", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{retries_enabled: false})
    issue = issue("ISS-6", "ABC-6", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      send(test_pid, {:runner_attempt, issue.id, Keyword.get(opts, :attempt)})
      {:error, failed_result(issue, "forced failure no retry")}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_attempt, "ISS-6", nil}
    refute_receive {:runner_attempt, "ISS-6", 1}, 200

    status = Orchestrator.status(orchestrator)
    assert status.retries_enabled == false
    assert status.retry_count == 0
  end

  test "marks max-turn runs resumable and schedules continuation", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{})
    issue = issue("ISS-MAX", "ABC-MAX", 1)
    test_pid = self()
    runner_calls = start_agent!(fn -> 0 end)

    ResumableTracker.put_state(test_pid, issue)
    on_exit(fn -> ResumableTracker.clear_state() end)

    runner = fn issue, opts ->
      call_number = Agent.get_and_update(runner_calls, fn count -> {count + 1, count + 1} end)
      send(test_pid, {:runner_attempt, call_number, Keyword.get(opts, :attempt)})

      case call_number do
        1 -> {:ok, max_turns_result(issue)}
        _ -> {:ok, success_result(issue)}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: ResumableTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 300,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_attempt, 1, nil}
    assert_receive {:tracker_mark_resumable, "ISS-MAX", %{status: :max_turns_reached}}

    status = Orchestrator.status(orchestrator)
    assert status.retry_count == 1

    assert [%{issue_id: "ISS-MAX", attempt: 1, reason: nil, due_in_ms: due_in_ms}] =
             status.retrying

    assert due_in_ms <= 300

    assert_receive {:runner_attempt, 2, 1}, 2_000
    assert_receive {:tracker_mark_done, "ISS-MAX", %{status: :ok}}

    status = Orchestrator.status(orchestrator)
    assert status.completed_count == 1
  end

  test "keeps done dependencies blocked and unblocks merged dependencies", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        tracker_active_states: ["open", "in_progress", "pending_merge", "merged"],
        tracker_terminal_states: ["done", "merged", "failed", "cancelled"]
      })

    test_pid = self()

    blocked_on_done = %{
      id: "ISS-BLOCKED",
      identifier: "US-BLOCKED",
      title: "Blocked by done",
      description: "Should remain blocked",
      state: "open",
      priority: 1,
      blocked_by: [
        %{id: "US-DEP-DONE", identifier: "US-DEP-DONE", title: "Dep done", state: "done"}
      ],
      created_at: "2026-01-01T00:00:00Z"
    }

    unblocked_on_merged = %{
      id: "ISS-READY",
      identifier: "US-READY",
      title: "Ready with merged dep",
      description: "Should dispatch",
      state: "open",
      priority: 2,
      blocked_by: [
        %{id: "US-DEP-MERGED", identifier: "US-DEP-MERGED", title: "Dep merged", state: "merged"}
      ],
      created_at: "2026-01-01T00:00:00Z"
    }

    issues_agent = start_agent!(fn -> [blocked_on_done, unblocked_on_merged] end)
    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-READY"}
    refute_receive {:runner_started, "ISS-BLOCKED"}, 100
  end

  test "does not dispatch pending_merge or merged stories", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        tracker_active_states: ["open", "in_progress", "pending_merge", "merged"],
        tracker_terminal_states: ["done", "merged", "failed", "cancelled"]
      })

    test_pid = self()

    issues = [
      %{issue("ISS-PENDING", "US-PENDING", 1) | state: "pending_merge"},
      %{issue("ISS-MERGED", "US-MERGED", 2) | state: "merged"},
      %{issue("ISS-OPEN", "US-OPEN", 3) | state: "open"}
    ]

    issues_agent = start_agent!(fn -> issues end)
    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-OPEN"}
    refute_receive {:runner_started, "ISS-PENDING"}, 100
    refute_receive {:runner_started, "ISS-MERGED"}, 100
  end

  test "stops ineligible running issue during reconciliation", %{root: root} do
    %{store: workflow_store} = start_workflow_store!(root, %{max_concurrent_agents: 1})
    issue = issue("ISS-4", "ABC-4", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      receive do
        {:complete_runner, ^issue_id, result} -> result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-4", runner_pid, nil}

    runner_ref = Process.monitor(runner_pid)
    Agent.update(issues_agent, fn _issues -> [] end)

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:killed, :shutdown]

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.retry_count == 0
    assert status.claimed_count == 0
  end

  test "auto polling triggers dispatch without manual poll", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{max_concurrent_agents: 1, poll_interval_ms: 25})

    issue = issue("ISS-5", "ABC-5", 1)
    test_pid = self()
    issues_agent = start_agent!(fn -> [issue] end)

    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, opts ->
      issue_id = issue.id
      send(test_pid, {:runner_started, issue_id, self(), Keyword.get(opts, :attempt)})

      receive do
        {:complete_runner, ^issue_id, result} -> result
      after
        5_000 -> {:error, failed_result(issue, "test timed out waiting for completion")}
      end
    end

    _orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: true,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert_receive {:runner_started, "ISS-5", runner_pid, nil}, 1_000
    send(runner_pid, {:complete_runner, "ISS-5", {:ok, success_result(issue)}})
  end

  test "watchdog keeps healthy auto polling loop marked fresh", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        poll_interval_ms: 25,
        stale_threshold_multiplier: 4,
        watchdog_check_interval_ms: 10
      })

    test_pid = self()

    tracker = fn _config ->
      send(test_pid, :tracker_polled)
      {:ok, []}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         auto_poll: true,
         retry_base_delay_ms: 20}
      )

    assert_receive :tracker_polled, 500
    assert_receive :tracker_polled, 500

    status = Orchestrator.status(orchestrator)

    assert status.watchdog.stale == false
    assert is_integer(status.watchdog.age_ms)
    assert status.watchdog.last_recovery_attempt == nil
  end

  test "watchdog forces one recovery poll for transient stale loop", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        poll_interval_ms: 200,
        stale_threshold_multiplier: 1,
        watchdog_check_interval_ms: 15
      })

    test_pid = self()

    tracker = fn _config ->
      send(test_pid, :tracker_polled)
      {:ok, []}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         auto_poll: true,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive :tracker_polled, 500

    force_stale_state!(orchestrator, 1_000)
    send(orchestrator, :watchdog_tick)

    status =
      wait_until!(fn ->
        status = Orchestrator.status(orchestrator)

        if is_map(status.watchdog.last_recovery_attempt) do
          {:ok, status}
        else
          :retry
        end
      end)

    assert status.watchdog.stale == false
    assert %{} = status.watchdog.last_recovery_attempt
    assert status.watchdog.last_recovery_attempt.outcome == :recovered
  end

  test "watchdog escalates to restart when stale persists after recovery", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        poll_interval_ms: 10,
        stale_threshold_multiplier: 1,
        watchdog_check_interval_ms: 10
      })

    name = unique_name(:orchestrator_watchdog)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, orchestrator} =
      DynamicSupervisor.start_child(supervisor, {
        Orchestrator,
        [
          name: name,
          workflow_store: workflow_store,
          tracker: fn _config -> {:ok, []} end,
          auto_poll: true,
          retry_base_delay_ms: 20
        ]
      })

    assert :ok = Orchestrator.poll_now(orchestrator)

    log =
      capture_log(fn ->
        ref = Process.monitor(orchestrator)
        force_persistent_stale_state!(orchestrator, 1_000)
        send(orchestrator, :watchdog_tick)

        assert_receive {:DOWN, ^ref, :process, ^orchestrator,
                        {:poll_watchdog_stale, _diagnostics}},
                       1_500
      end)

    assert log =~ "orchestrator_event=poll_watchdog_restart"

    restarted = wait_for_registered_restart!(name, orchestrator)
    assert is_pid(restarted)
    assert restarted != orchestrator
  end

  test "marks prd_json story done after successful run", %{root: root} do
    prd_path = Path.join(root, "prd.json")
    write_prd!(prd_path)

    %{store: workflow_store} =
      start_workflow_store!(root, %{
        tracker_kind: "prd_json",
        tracker_path: prd_path,
        tracker_active_states: ["open", "in_progress"],
        tracker_terminal_states: ["done"]
      })

    test_pid = self()

    runner = fn issue, opts ->
      send(test_pid, {:runner_started, issue.id, self(), Keyword.get(opts, :attempt)})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         runner: runner,
         auto_poll: false,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "US-001", runner_pid, nil}

    runner_ref = Process.monitor(runner_pid)
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:normal, :noproc]

    _ = :sys.get_state(orchestrator)

    assert prd_story_status(prd_path, "US-001") == "done"

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.retry_count == 0
    assert status.claimed_count == 0
    assert status.completed_count == 1
  end

  test "marks issue merged when publish_merged event is present", %{root: root} do
    issue = issue("ISS-MERGED", "ABC-MERGED", 1)

    config = %Config{
      tracker: %{
        kind: "merge_test",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Merged", "Cancelled"],
        test_pid: self(),
        test_issues: [issue]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{},
      git: %{base_branch: "main"},
      raw: %{}
    }

    runner = fn issue, _opts ->
      {:ok, %{success_result(issue) | events: [%{type: :publish_merged}]}}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:tracker_mark_done, "ISS-MERGED"}
    assert_receive {:tracker_mark_merged, "ISS-MERGED"}
  end

  test "keeps issue pending_merge when publish creates PR", %{root: root} do
    issue = issue("ISS-PENDING", "ABC-PENDING", 1)

    config = %Config{
      tracker: %{
        kind: "merge_test",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Merged", "Cancelled"],
        test_pid: self(),
        test_issues: [issue]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{},
      git: %{base_branch: "main"},
      raw: %{}
    }

    runner = fn issue, _opts ->
      {:ok,
       %{
         success_result(issue)
         | events: [%{type: :publish_pr_created, pr_url: "https://example.test/pulls/1"}]
       }}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:tracker_mark_pending_merge, "ISS-PENDING"}
    refute_receive {:tracker_mark_done, "ISS-PENDING"}, 100
  end

  test "marks done when merge fails without PR", %{root: root} do
    issue = issue("ISS-MERGE-FAIL", "ABC-MERGE-FAIL", 1)

    config = %Config{
      tracker: %{
        kind: "merge_test",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Merged", "Cancelled"],
        test_pid: self(),
        test_issues: [issue]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{},
      git: %{base_branch: "main"},
      raw: %{}
    }

    runner = fn issue, _opts ->
      {:ok,
       %{success_result(issue) | events: [%{type: :publish_merge_failed, reason: "conflict"}]}}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeTracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:tracker_mark_done, "ISS-MERGE-FAIL"}
    refute_receive {:tracker_mark_pending_merge, "ISS-MERGE-FAIL"}, 100
  end

  test "detects merged pending_merge story and marks tracker merged", %{root: root} do
    pending_issue =
      issue("ISS-PM-1", "ABC-PM-1", 1)
      |> Map.put(:state, "pending_merge")
      |> Map.put(:pr_url, "https://example.test/pulls/1")

    dependent_issue =
      issue("ISS-DEP-1", "ABC-DEP-1", 2)
      |> Map.put(:blocked_by, [%{id: "ISS-PM-1", state: "pending_merge"}])

    MergeDetectionTracker.put_state(self(), [pending_issue, dependent_issue])
    on_exit(&MergeDetectionTracker.clear_state/0)

    config = %Config{
      tracker: %{
        kind: "merge_detection_test",
        active_states: ["Todo", "In Progress", "pending_merge", "merged"],
        terminal_states: ["Done", "Merged", "Cancelled"]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{provider: :github},
      git: %{base_branch: "main"},
      raw: %{}
    }

    test_pid = self()

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    merge_checker = fn _config, "https://example.test/pulls/1" -> {:ok, true} end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeDetectionTracker,
         runner: runner,
         merge_checker: merge_checker,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)

    assert_receive {:tracker_mark_merged, "ISS-PM-1"}
    refute_receive {:runner_started, "ISS-DEP-1"}, 100

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-DEP-1"}
  end

  test "keeps pending_merge story when PR remains open", %{root: root} do
    pending_issue =
      issue("ISS-PM-OPEN", "ABC-PM-OPEN", 1)
      |> Map.put(:state, "pending_merge")
      |> Map.put(:pr_url, "https://example.test/pulls/2")

    dependent_issue =
      issue("ISS-DEP-OPEN", "ABC-DEP-OPEN", 2)
      |> Map.put(:blocked_by, [%{id: "ISS-PM-OPEN", state: "pending_merge"}])

    MergeDetectionTracker.put_state(self(), [pending_issue, dependent_issue])
    on_exit(&MergeDetectionTracker.clear_state/0)

    config = %Config{
      tracker: %{
        kind: "merge_detection_test",
        active_states: ["Todo", "In Progress", "pending_merge", "merged"],
        terminal_states: ["Done", "Merged", "Cancelled"]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{provider: :github},
      git: %{base_branch: "main"},
      raw: %{}
    }

    runner = fn issue, _opts -> {:ok, success_result(issue)} end
    merge_checker = fn _config, _pr_url -> {:ok, false} end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeDetectionTracker,
         runner: runner,
         merge_checker: merge_checker,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    refute_receive {:tracker_mark_merged, "ISS-PM-OPEN"}, 100
    refute_receive {:runner_started, "ISS-DEP-OPEN"}, 100
  end

  test "continues poll cycle when merge check fails", %{root: root} do
    pending_issue =
      issue("ISS-PM-ERR", "ABC-PM-ERR", 1)
      |> Map.put(:state, "pending_merge")
      |> Map.put(:pr_url, "https://example.test/pulls/3")

    dependent_issue =
      issue("ISS-DEP-ERR", "ABC-DEP-ERR", 2)
      |> Map.put(:blocked_by, [%{id: "ISS-PM-ERR", state: "pending_merge"}])

    MergeDetectionTracker.put_state(self(), [pending_issue, dependent_issue])
    on_exit(&MergeDetectionTracker.clear_state/0)

    config = %Config{
      tracker: %{
        kind: "merge_detection_test",
        active_states: ["Todo", "In Progress", "pending_merge", "merged"],
        terminal_states: ["Done", "Merged", "Cancelled"]
      },
      polling: %{interval_ms: 1000},
      workspace: %{root: Path.join(root, "workspaces"), strategy: :clone},
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: false,
        max_attempts: 1,
        max_retry_backoff_ms: 1000
      },
      publish: %{provider: :github},
      git: %{base_branch: "main"},
      raw: %{}
    }

    runner = fn issue, _opts -> {:ok, success_result(issue)} end
    merge_checker = fn _config, _pr_url -> {:error, "forced cli failure"} end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config,
         tracker: MergeDetectionTracker,
         runner: runner,
         merge_checker: merge_checker,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    log = capture_log(fn -> assert :ok = Orchestrator.poll_now(orchestrator) end)

    assert log =~ "Failed to check merge status"
    refute_receive {:tracker_mark_merged, "ISS-PM-ERR"}, 100
    refute_receive {:runner_started, "ISS-DEP-ERR"}, 100
  end

  test "dispatches issue when blocker state is merged", %{root: root} do
    %{store: workflow_store} =
      start_workflow_store!(root, %{
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Merged", "Cancelled"]
      })

    test_pid = self()

    issue =
      issue("ISS-BLOCKED", "ABC-BLOCKED", 1)
      |> Map.put(:blocked_by, [%{id: "ISS-DEP", state: "Merged"}])

    issues_agent = start_agent!(fn -> [issue] end)
    tracker = fn _config -> {:ok, Agent.get(issues_agent, & &1)} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: workflow_store,
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         continuation_delay_ms: 60_000,
         retry_base_delay_ms: 20}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-BLOCKED"}
  end

  defp issue(id, identifier, priority) do
    %{
      id: id,
      identifier: identifier,
      title: "Issue #{identifier}",
      description: "Test issue",
      state: "Todo",
      priority: priority,
      created_at: "2026-01-01T00:00:00Z",
      blocked_by: []
    }
  end

  defp success_result(issue) do
    now = DateTime.utc_now()

    %Result{
      issue_id: issue.id,
      identifier: issue.identifier,
      workspace_path: nil,
      turn_count: 1,
      status: :ok,
      started_at: now,
      ended_at: now,
      last_output: "ok",
      events: [],
      error: nil
    }
  end

  defp failed_result(issue, reason) do
    now = DateTime.utc_now()

    %Result{
      issue_id: issue.id,
      identifier: issue.identifier,
      workspace_path: nil,
      turn_count: 1,
      status: :failed,
      started_at: now,
      ended_at: now,
      last_output: nil,
      events: [],
      error: reason
    }
  end

  defp max_turns_result(issue) do
    now = DateTime.utc_now()

    %Result{
      issue_id: issue.id,
      identifier: issue.identifier,
      workspace_path: nil,
      turn_count: 5,
      status: :max_turns_reached,
      started_at: now,
      ended_at: now,
      last_output: "max turns reached",
      events: [],
      error: nil
    }
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
  end

  defp force_stale_state!(orchestrator, age_ms) when is_integer(age_ms) and age_ms > 0 do
    :sys.replace_state(orchestrator, fn state ->
      if state.poll_timer_ref, do: Process.cancel_timer(state.poll_timer_ref)

      %{
        state
        | poll_timer_ref: nil,
          last_poll_at: DateTime.add(DateTime.utc_now(), -1, :second),
          last_poll_monotonic_ms: System.monotonic_time(:millisecond) - age_ms,
          poll_stale: false,
          poll_stale_detected_at: nil,
          poll_stale_recovery_attempted: false
      }
    end)
  end

  defp force_persistent_stale_state!(orchestrator, age_ms)
       when is_integer(age_ms) and age_ms > 0 do
    :sys.replace_state(orchestrator, fn state ->
      if state.poll_timer_ref, do: Process.cancel_timer(state.poll_timer_ref)

      %{
        state
        | poll_timer_ref: nil,
          last_poll_at: DateTime.add(DateTime.utc_now(), -1, :second),
          last_poll_monotonic_ms: System.monotonic_time(:millisecond) - age_ms,
          poll_stale: true,
          poll_stale_detected_at: DateTime.add(DateTime.utc_now(), -1, :second),
          poll_stale_recovery_attempted: true
      }
    end)
  end

  defp wait_for_registered_restart!(name, previous_pid, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_registered_restart(name, previous_pid, deadline)
  end

  defp wait_until!(fun, timeout_ms \\ 2_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("expected condition to become true")
        else
          Process.sleep(20)
          do_wait_until(fun, deadline)
        end

      other ->
        flunk("wait_until callback must return {:ok, value} or :retry, got: #{inspect(other)}")
    end
  end

  defp do_wait_for_registered_restart(name, previous_pid, deadline) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        pid

      _other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("expected orchestrator #{inspect(name)} to restart")
        else
          Process.sleep(20)
          do_wait_for_registered_restart(name, previous_pid, deadline)
        end
    end
  end

  defp start_agent!(initializer) when is_function(initializer, 0) do
    start_supervised!(%{
      id: unique_name(:agent),
      start: {Agent, :start_link, [initializer]}
    })
  end

  defp start_workflow_store!(root, opts) do
    workspace_root = Path.join(root, "workspaces")

    content =
      workflow_content(%{
        workspace_root: workspace_root,
        poll_interval_ms: Map.get(opts, :poll_interval_ms, 1000),
        tracker_kind: Map.get(opts, :tracker_kind, "linear"),
        tracker_path: Map.get(opts, :tracker_path),
        tracker_active_states: Map.get(opts, :tracker_active_states, ["Todo", "In Progress"]),
        tracker_terminal_states: Map.get(opts, :tracker_terminal_states, ["Done", "Cancelled"]),
        max_concurrent_agents: Map.get(opts, :max_concurrent_agents, 2),
        max_retry_backoff_ms: Map.get(opts, :max_retry_backoff_ms, 300_000),
        retries_enabled: Map.get(opts, :retries_enabled, true),
        stale_threshold_multiplier: Map.get(opts, :stale_threshold_multiplier),
        watchdog_check_interval_ms: Map.get(opts, :watchdog_check_interval_ms),
        runtime_profile: Map.get(opts, :runtime_profile, "checks_only")
      })

    path = Path.join(root, "workflow_#{System.unique_integer([:positive])}.md")
    File.write!(path, content)

    store =
      start_supervised!({WorkflowStore, path: path, name: unique_name(:workflow_store)})

    %{store: store, path: path}
  end

  defp workflow_content(%{workspace_root: workspace_root} = opts) do
    tracker_path_line =
      case Map.get(opts, :tracker_path) do
        nil -> ""
        path -> "\n  path: #{path}"
      end

    tracker_active_states =
      opts
      |> Map.get(:tracker_active_states, ["Todo", "In Progress"])
      |> yaml_list(4)

    tracker_terminal_states =
      opts
      |> Map.get(:tracker_terminal_states, ["Done", "Cancelled"])
      |> yaml_list(4)

    stale_threshold_multiplier_line =
      case Map.get(opts, :stale_threshold_multiplier) do
        value when is_integer(value) and value > 0 ->
          "\n  stale_threshold_multiplier: #{value}"

        _other ->
          ""
      end

    watchdog_check_interval_line =
      case Map.get(opts, :watchdog_check_interval_ms) do
        value when is_integer(value) and value > 0 ->
          "\n  watchdog_check_interval_ms: #{value}"

        _other ->
          ""
      end

    """
    ---
    tracker:
      kind: #{Map.get(opts, :tracker_kind, "linear")}#{tracker_path_line}
      active_states:
    #{tracker_active_states}
      terminal_states:
    #{tracker_terminal_states}
    polling:
      interval_ms: #{Map.get(opts, :poll_interval_ms, 1000)}#{stale_threshold_multiplier_line}#{watchdog_check_interval_line}
    runtime:
      profile: #{Map.get(opts, :runtime_profile, "checks_only")}
    workspace:
      root: #{workspace_root}
      strategy: clone
    agent:
      kind: amp
      max_concurrent_agents: #{Map.get(opts, :max_concurrent_agents, 2)}
      max_turns: 5
      max_retry_backoff_ms: #{Map.get(opts, :max_retry_backoff_ms, 300_000)}
      retries_enabled: #{Map.get(opts, :retries_enabled, true)}
      max_attempts: #{Map.get(opts, :max_attempts, 10)}
    ---
    Work on {{ issue.identifier }}
    """
  end

  defp yaml_list(values, indent) when is_list(values) do
    prefix = String.duplicate(" ", indent)

    values
    |> Enum.map_join("\n", fn value -> "#{prefix}- #{value}" end)
  end

  defp write_prd!(path) do
    data = %{
      "project" => "kollywood",
      "branchName" => "dogfood/prd-json-tracker",
      "description" => "Dogfood PRD",
      "userStories" => [
        %{
          "id" => "US-001",
          "title" => "Mark me done",
          "description" => "Run one orchestrator issue and mark it done.",
          "acceptanceCriteria" => ["Issue is marked done in PRD"],
          "priority" => 1,
          "status" => "open",
          "dependsOn" => []
        }
      ]
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp prd_story_status(path, story_id) do
    {:ok, content} = File.read(path)
    {:ok, data} = Jason.decode(content)

    data
    |> Map.fetch!("userStories")
    |> Enum.find(fn story -> Map.get(story, "id") == story_id end)
    |> Map.get("status")
  end

  defp read_json!(path) do
    {:ok, content} = File.read(path)
    {:ok, decoded} = Jason.decode(content)
    decoded
  end
end
