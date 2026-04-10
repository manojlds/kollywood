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

  defmodule QueueMergeTracker do
    @behaviour Kollywood.Tracker

    alias Kollywood.Config

    @impl true
    def list_active_issues(%Config{} = config) do
      {:ok, get_in(config, [Access.key(:tracker, %{}), Access.key(:test_issues, [])])}
    end

    @impl true
    def list_pending_merge_issues(_config), do: {:ok, []}

    @impl true
    def claim_issue(_config, _issue_id), do: :ok

    @impl true
    def mark_in_progress(_config, _issue_id), do: :ok

    @impl true
    def mark_resumable(_config, _issue_id, _done_metadata), do: :ok

    @impl true
    def mark_done(%Config{} = config, issue_id, _metadata) do
      notify(config, {:tracker_mark_done, issue_id})
      :ok
    end

    @impl true
    def mark_pending_merge(_config, _issue_id, _metadata), do: :ok

    @impl true
    def mark_merged(%Config{} = config, issue_id, _metadata) do
      notify(config, {:tracker_mark_merged, issue_id})
      :ok
    end

    @impl true
    def mark_failed(_config, _issue_id, _reason, _attempt), do: :ok

    defp notify(config, message) do
      case get_in(config, [Access.key(:tracker, %{}), Access.key(:test_pid)]) do
        pid when is_pid(pid) -> send(pid, message)
        _other -> :ok
      end
    end
  end

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

  test "queue dispatch preserves publish_merged event for tracker finalization" do
    suffix = System.unique_integer([:positive])
    issue_id = "issue-q-merge-#{suffix}"
    identifier = "US-Q-MERGE-#{suffix}"

    issue = %{
      "id" => issue_id,
      "identifier" => identifier,
      "title" => "Queue merge event",
      "description" => "Ensure queue result retains publish events",
      "priority" => 1,
      "state" => "open",
      "status" => "open"
    }

    tracker_config =
      @test_config.tracker
      |> Map.put(:kind, "queue_merge_test")
      |> Map.put(:test_pid, self())
      |> Map.put(:test_issues, [issue])

    workflow_store = %Config{@test_config | tracker: tracker_config}

    {:ok, pool} = Kollywood.AgentPool.start_link(name: nil)

    {:ok, orch} =
      Orchestrator.start_link(
        name: nil,
        workflow_store: workflow_store,
        tracker: QueueMergeTracker,
        runner: fn _issue, _opts ->
          now = DateTime.utc_now()
          {:ok, %Result{status: :ok, started_at: now, ended_at: now}}
        end,
        agent_pool: pool,
        auto_poll: false,
        dispatch_mode: :queue,
        ephemeral_store: nil,
        retry_store: nil,
        retries_enabled: false,
        poll_interval_ms: 60_000
      )

    capture_log(fn -> assert :ok = Orchestrator.poll_now(orch) end)

    entry =
      RunQueue.list_by_status(["pending", "claimed", "running", "completed"])
      |> Enum.find(&(&1.issue_id == issue_id))

    assert entry

    result_payload = %{
      "status" => "ok",
      "issue_id" => issue_id,
      "identifier" => identifier,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "ended_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "events" => [
        %{
          "type" => "publish_merged",
          "base_branch" => "main",
          "branch" => "kollywood/#{identifier}"
        }
      ]
    }

    send(orch, {:run_queue, {:completed, entry.id, entry.issue_id, result_payload}})

    assert_receive {:tracker_mark_done, ^issue_id}, 2_000
    assert_receive {:tracker_mark_merged, ^issue_id}, 2_000
  end

  test "leader election allows only one orchestrator to enqueue" do
    suffix = System.unique_integer([:positive])
    issue_id = "issue-q-leader-#{suffix}"

    issue = %{
      "id" => issue_id,
      "identifier" => "US-Q-LEADER-#{suffix}",
      "title" => "Leader election queue dispatch",
      "description" => "Only one orchestrator should enqueue",
      "priority" => 1,
      "state" => "open",
      "status" => "open"
    }

    tracker = fn _config -> {:ok, [issue]} end
    {:ok, pool_a} = Kollywood.AgentPool.start_link(name: nil)
    {:ok, pool_b} = Kollywood.AgentPool.start_link(name: nil)

    common_opts = [
      workflow_store: @test_config,
      tracker: tracker,
      runner: fn _issue, _opts -> raise "should not run locally" end,
      auto_poll: false,
      dispatch_mode: :queue,
      ephemeral_store: nil,
      retry_store: nil,
      retries_enabled: false,
      poll_interval_ms: 60_000,
      leader_election_enabled: true,
      leader_lease_name: "test-orchestrator-lease-#{suffix}",
      leader_lease_ttl_ms: 10_000,
      leader_lease_refresh_interval_ms: 1_000
    ]

    {:ok, orch_a} =
      Orchestrator.start_link(
        Keyword.merge(common_opts,
          name: nil,
          agent_pool: pool_a,
          leader_owner_id: "orch-a-#{suffix}"
        )
      )

    {:ok, orch_b} =
      Orchestrator.start_link(
        Keyword.merge(common_opts,
          name: nil,
          agent_pool: pool_b,
          leader_owner_id: "orch-b-#{suffix}"
        )
      )

    status_a = Orchestrator.status(orch_a)
    status_b = Orchestrator.status(orch_b)

    assert status_a.leader? != status_b.leader?

    capture_log(fn ->
      Orchestrator.poll_now(orch_a)
      Orchestrator.poll_now(orch_b)
    end)

    entries = RunQueue.list_by_status(["pending", "claimed", "running"])
    issue_entries = Enum.filter(entries, &(&1.issue_id == issue_id))
    assert length(issue_entries) == 1
  end
end
