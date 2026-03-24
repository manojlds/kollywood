defmodule Kollywood.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Orchestrator
  alias Kollywood.WorkflowStore

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
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}

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

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
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

    """
    ---
    tracker:
      kind: #{Map.get(opts, :tracker_kind, "linear")}#{tracker_path_line}
      active_states:
    #{tracker_active_states}
      terminal_states:
    #{tracker_terminal_states}
    polling:
      interval_ms: #{Map.get(opts, :poll_interval_ms, 1000)}
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
end
