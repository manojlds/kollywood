defmodule Mix.Tasks.Kollywood.OrchTasksTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kollywood.Config
  alias Kollywood.Orchestrator

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_orch_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    server = :kollywood_orch_task_server

    previous_server_env = Application.get_env(:kollywood, :orchestrator_server)
    Application.put_env(:kollywood, :orchestrator_server, server)

    on_exit(fn ->
      File.rm_rf!(root)

      if is_nil(previous_server_env) do
        Application.delete_env(:kollywood, :orchestrator_server)
      else
        Application.put_env(:kollywood, :orchestrator_server, previous_server_env)
      end
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
    assert_receive {:DOWN, ^runner_ref, :process, ^runner_pid, :killed}

    status = Orchestrator.status(orchestrator)
    assert status.running_count == 0
    assert status.claimed_count == 0
  end

  defp run_task(task_name, args) do
    Mix.Task.reenable(task_name)
    capture_io(fn -> Mix.Task.run(task_name, args) end)
  end

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
