defmodule Kollywood.OrchestratorQueueDispatchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator
  alias Kollywood.Repo
  alias Kollywood.RunQueue

  @test_config %Config{
    tracker: %{
      active_states: ["open", "in_progress"],
      terminal_states: ["done", "failed"],
      kind: "prd_json"
    },
    agent: %{kind: :pi, max_turns: 5, timeout_ms: 60_000},
    workspace: %{strategy: :directory},
    quality: %{max_cycles: 1},
    hooks: %{},
    checks: %{},
    runtime: %{},
    review: %{},
    testing: %{},
    preview: %{},
    publish: %{},
    git: %{},
    raw: %{}
  }

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp start_orchestrator(opts) do
    test_pid = self()

    issue = %{
      "id" => "issue-q-1",
      "identifier" => "US-Q1",
      "title" => "Queue dispatch test",
      "description" => "Test queue-based dispatch",
      "priority" => 1,
      "state" => "open",
      "status" => "open"
    }

    tracker = fn _config ->
      {:ok, [issue]}
    end

    runner = fn _issue, _opts ->
      send(test_pid, :runner_invoked)
      now = DateTime.utc_now()
      {:ok, %Result{status: :ok, started_at: now, ended_at: now}}
    end

    agent_pool_opts = [name: nil]
    {:ok, pool} = Kollywood.AgentPool.start_link(agent_pool_opts)

    default_opts = [
      name: nil,
      workflow_store: @test_config,
      tracker: tracker,
      runner: runner,
      agent_pool: pool,
      auto_poll: false,
      dispatch_mode: :queue,
      ephemeral_store: nil,
      retry_store: nil,
      retries_enabled: false,
      poll_interval_ms: 60_000
    ]

    merged_opts = Keyword.merge(default_opts, opts)
    Orchestrator.start_link(merged_opts)
  end

  test "orchestrator enqueues to RunQueue in :queue dispatch mode" do
    {:ok, orch} = start_orchestrator([])

    capture_log(fn ->
      Orchestrator.poll_now(orch)
      Process.sleep(200)
    end)

    pending = RunQueue.list_by_status(["pending", "claimed", "running"])
    assert length(pending) >= 1

    entry = hd(pending)
    assert entry.issue_id == "issue-q-1"
    assert entry.identifier == "US-Q1"
  end

  test "orchestrator does NOT start local workers in :queue mode" do
    {:ok, orch} = start_orchestrator([])

    capture_log(fn ->
      Orchestrator.poll_now(orch)
    end)

    Process.sleep(100)

    refute_received :runner_invoked
  end

  test "orchestrator tracks queued run in running state" do
    {:ok, orch} = start_orchestrator([])

    capture_log(fn ->
      Orchestrator.poll_now(orch)
    end)

    Process.sleep(100)

    status = Orchestrator.status(orch)
    running = status.running
    running_count = if is_list(running), do: length(running), else: map_size(running)
    assert running_count >= 1
  end
end
