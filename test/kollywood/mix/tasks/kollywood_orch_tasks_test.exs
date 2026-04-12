defmodule Mix.Tasks.Kollywood.OrchTasksTest do
  use Kollywood.DataCase, async: false

  import ExUnit.CaptureIO

  alias Kollywood.Config
  alias Kollywood.Orchestrator
  alias Kollywood.Orchestrator.ControlState
  alias Kollywood.Orchestrator.RunLogs

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_orch_task_test_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    File.mkdir_p!(root)

    server = :kollywood_orch_task_server
    workflow_path = write_workflow!(root)

    previous_server_env = Application.get_env(:kollywood, :orchestrator_server)
    previous_workflow_path_env = Application.get_env(:kollywood, :workflow_path)
    previous_follow_poll_ms = Application.get_env(:kollywood, :orch_logs_follow_poll_ms)

    Application.put_env(:kollywood, :orchestrator_server, server)
    Application.put_env(:kollywood, :workflow_path, workflow_path)
    Application.put_env(:kollywood, :orch_logs_follow_poll_ms, 25)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)

      restore_env(:orchestrator_server, previous_server_env)
      restore_env(:workflow_path, previous_workflow_path_env)
      restore_env(:orch_logs_follow_poll_ms, previous_follow_poll_ms)
    end)

    %{root: root, server: server}
  end

  test "kollywood.orch.status prints runtime snapshot", %{root: root, server: server} do
    _orchestrator =
      start_supervised!(
        {Orchestrator,
         name: server,
         workflow_store: workflow_config(root),
         tracker: fn _config -> {:ok, []} end,
         auto_poll: false}
      )

    output = run_task("kollywood.orch.status", [])

    assert output =~ "Orchestrator status"
    assert output =~ "running=0"
    assert output =~ "retrying=0"
    assert output =~ "maintenance_mode=normal"
    assert output =~ "dispatch_paused=false"
    assert output =~ "drain_ready=true"
    assert output =~ "max_concurrent_agents_requested=1"
    assert output =~ "max_concurrent_agents_effective=1"
    assert output =~ "max_concurrent_agents_hard_cap=5"
    assert output =~ "poll_stale=false"
    assert output =~ "last_recovery_attempt=none"
  end

  test "kollywood.orch.status shows runtime state for running issue", %{
    root: root,
    server: server
  } do
    issue = issue("US-777")
    issues_agent = start_list_agent([issue])
    test_pid = self()

    config =
      workflow_config(root)
      |> put_in([Access.key(:runtime), Access.key(:processes)], ["server"])

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: server,
         workflow_store: config,
         tracker: fn _config -> {:ok, Agent.get(issues_agent, & &1)} end,
         runner: fn issue, opts ->
           issue_id = issue.id
           on_event = Keyword.fetch!(opts, :on_event)

           send(test_pid, {:runner_started, issue_id, self()})

           on_event.(%{type: :runtime_starting, timestamp: DateTime.utc_now()})
           on_event.(%{type: :runtime_started, timestamp: DateTime.utc_now()})

           receive do
             {:complete_runner, ^issue_id, result} -> result
           end
         end,
         auto_poll: false}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "US-777", runner_pid}

    # Sync twice: runner sends on_event after the runner_started message,
    # so we need to yield then flush the orchestrator's mailbox.
    Process.sleep(10)
    _ = :sys.get_state(orchestrator)

    output = run_task("kollywood.orch.status", [])

    assert output =~ "runtime_profile=full_stack"
    assert output =~ "runtime_state=running"
    assert output =~ "runtime_event=runtime_started"

    runner_ref = Process.monitor(runner_pid)
    assert :ok = Orchestrator.stop_issue(orchestrator, "US-777")
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:killed, :shutdown]
  end

  test "kollywood.orch.poll triggers a poll cycle", %{root: root, server: server} do
    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: server,
         workflow_store: workflow_config(root),
         tracker: fn _config -> {:ok, []} end,
         auto_poll: false}
      )

    assert Orchestrator.status(orchestrator).last_poll_at == nil

    output = run_task("kollywood.orch.poll", [])

    assert output =~ "Poll completed"
    assert %DateTime{} = Orchestrator.status(orchestrator).last_poll_at
  end

  test "kollywood.orch.stop stops one running issue", %{root: root, server: server} do
    issue = issue("US-501")
    issues_agent = start_list_agent([issue])
    test_pid = self()

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: server,
         workflow_store: workflow_config(root),
         tracker: fn _config -> {:ok, Agent.get(issues_agent, & &1)} end,
         runner: fn issue, _opts ->
           issue_id = issue.id
           send(test_pid, {:runner_started, issue.id, self()})

           receive do
             {:complete_runner, ^issue_id, result} -> result
           end
         end,
         auto_poll: false}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "US-501", runner_pid}

    runner_ref = Process.monitor(runner_pid)

    output = run_task("kollywood.orch.stop", ["US-501"])

    assert output =~ "Requested stop for issue US-501"
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, reason}
    assert reason in [:killed, :shutdown]

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.claimed_count == 0
  end

  test "kollywood.orch.logs prints latest and specific attempt logs", %{root: root} do
    _run_log_one =
      write_attempt_log_fixture(root, "US-900", 1, "[first] worker output\n", "failed")

    _run_log_two =
      write_attempt_log_fixture(root, "US-900", 2, "[second] worker output\n", "ok")

    latest_output = run_task("kollywood.orch.logs", ["US-900"])

    assert latest_output =~ "attempt #2"
    assert latest_output =~ "[second] worker output"
    refute latest_output =~ "[first] worker output"

    specific_output = run_task("kollywood.orch.logs", ["US-900", "--attempt", "1"])

    assert specific_output =~ "attempt #1"
    assert specific_output =~ "[first] worker output"
  end

  test "kollywood.orch.logs shows recovery guidance from metadata", %{root: root} do
    _run_log_path =
      write_attempt_log_fixture(root, "US-902", 1, "[seed] worker output\n", "failed",
        recovery_guidance: %{
          "summary" => "workspace cleanup preserved",
          "commands" => [
            "ls -la /tmp/kollywood/workspaces/US-902",
            "git -C /tmp/kollywood/workspaces/US-902 status --short"
          ]
        }
      )

    output = run_task("kollywood.orch.logs", ["US-902"])

    assert output =~ "recovery_guidance:"
    assert output =~ "workspace cleanup preserved"
    assert output =~ "Recovery commands:"
    assert output =~ "git -C /tmp/kollywood/workspaces/US-902 status --short"
  end

  test "kollywood.orch.logs follow mode streams appended lines", %{root: root} do
    run_log_path =
      write_attempt_log_fixture(root, "US-901", 1, "[seed] line\n", "running")

    output =
      capture_io(fn ->
        follower_pid =
          spawn(fn ->
            Mix.Task.reenable("kollywood.orch.logs")
            Mix.Task.run("kollywood.orch.logs", ["US-901", "--attempt", "1", "--follow"])
          end)

        Process.sleep(120)
        File.write!(run_log_path, "[tail] line\n", [:append])
        Process.sleep(220)
        Process.exit(follower_pid, :kill)
        Process.sleep(80)
      end)

    assert output =~ "[seed] line"
    assert output =~ "[tail] line"
  end

  test "kollywood.orch.maintenance toggles maintenance mode file" do
    output = run_task("kollywood.orch.maintenance", ["--mode", "drain"])

    assert output =~ "Maintenance mode set to drain"
    assert output =~ "Current maintenance mode: drain"
    assert {:ok, :drain} = ControlState.read_maintenance_mode()

    output = run_task("kollywood.orch.maintenance", ["--mode", "normal"])

    assert output =~ "Maintenance mode set to normal"
    assert output =~ "Current maintenance mode: normal"
    assert {:ok, :normal} = ControlState.read_maintenance_mode()
  end

  test "kollywood.orch.maintenance waits until drain is ready" do
    assert :ok = ControlState.write_status(%{maintenance_mode: "drain", running_count: 0})

    output =
      run_task("kollywood.orch.maintenance", [
        "--mode",
        "drain",
        "--wait",
        "--timeout",
        "2",
        "--interval",
        "25"
      ])

    assert output =~ "Current maintenance mode: drain"
    assert output =~ "Drain complete (running=0)"
  end

  defp run_task(task_name, args) do
    Mix.Task.reenable(task_name)
    capture_io(fn -> Mix.Task.run(task_name, args) end)
  end

  defp write_workflow!(root) do
    tracker_path = Path.join(root, "prd.json")

    File.write!(tracker_path, Jason.encode!(%{"project" => "kollywood", "userStories" => []}))

    workflow_path = Path.join(root, "WORKFLOW.md")

    File.write!(workflow_path, """
    ---
    tracker:
      kind: prd_json
      path: #{tracker_path}
    workspace:
      root: #{Path.join(root, "workspaces")}
      strategy: clone
    agent:
      kind: amp
    ---
    Work on {{ issue.identifier }}
    """)

    workflow_path
  end

  defp write_attempt_log_fixture(root, story_id, attempt, run_log_content, status, opts \\ []) do
    project_root =
      root
      |> workflow_config()
      |> RunLogs.project_root()

    attempt_dir =
      Path.join([
        project_root,
        "run_logs",
        story_id,
        "attempt-" <> String.pad_leading(Integer.to_string(attempt), 4, "0")
      ])

    File.mkdir_p!(attempt_dir)

    run_log_path = Path.join(attempt_dir, "run.log")
    File.write!(run_log_path, run_log_content)

    File.write!(Path.join(attempt_dir, "worker.log"), run_log_content)
    File.write!(Path.join(attempt_dir, "reviewer.log"), "")
    File.write!(Path.join(attempt_dir, "checks.log"), "")
    File.write!(Path.join(attempt_dir, "runtime.log"), "")
    File.write!(Path.join(attempt_dir, "events.jsonl"), "")

    metadata =
      %{
        "story_id" => story_id,
        "attempt" => attempt,
        "status" => status,
        "started_at" => "2026-03-24T00:00:00Z",
        "ended_at" => "2026-03-24T00:00:10Z"
      }
      |> then(fn base ->
        case Keyword.get(opts, :recovery_guidance) do
          guidance when is_map(guidance) -> Map.put(base, "recovery_guidance", guidance)
          _other -> base
        end
      end)

    File.write!(Path.join(attempt_dir, "metadata.json"), Jason.encode!(metadata, pretty: true))

    run_log_path
  end

  defp restore_env(key, nil), do: Application.delete_env(:kollywood, key)
  defp restore_env(key, value), do: Application.put_env(:kollywood, key, value)

  defp workflow_config(root) do
    %Config{
      tracker: %{
        kind: "prd_json",
        path: Path.join(root, "prd.json"),
        active_states: ["open", "in_progress"],
        terminal_states: ["done"]
      },
      polling: %{interval_ms: 1_000},
      workspace: %{root: root, strategy: :clone},
      hooks: %{
        after_create: nil,
        before_run: nil,
        after_run: nil,
        before_remove: nil
      },
      checks: %{required: [], timeout_ms: 10_000, fail_fast: true},
      runtime: %{
        kind: :host,
        command: "pitchfork",
        processes: [],
        env: %{},
        ports: %{},
        port_offset_mod: 1000,
        start_timeout_ms: 120_000,
        stop_timeout_ms: 60_000
      },
      review: %{enabled: false, max_cycles: 1, agent: %{kind: :amp}},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        max_retry_backoff_ms: 1_000,
        command: nil,
        args: [],
        env: %{},
        timeout_ms: 1_000
      },
      raw: %{}
    }
  end

  defp issue(id) do
    %{
      id: id,
      identifier: id,
      title: "Issue #{id}",
      description: "Task #{id}",
      state: "open",
      priority: 1,
      blocked_by: [],
      created_at: nil
    }
  end

  defp start_list_agent(initial) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> initial end]}})
  end
end
