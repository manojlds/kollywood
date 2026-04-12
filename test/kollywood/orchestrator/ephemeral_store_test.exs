defmodule Kollywood.Orchestrator.EphemeralStoreTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator
  alias Kollywood.Orchestrator.EphemeralStore

  setup do
    assert :ok = EphemeralStore.clear()
    :ok
  end

  test "stores active markers and prunes expired ones" do
    now_ms = System.monotonic_time(:millisecond)

    assert :ok = EphemeralStore.upsert(:claimed, "ISS-CLAIMED", now_ms + 1_000)
    assert :ok = EphemeralStore.upsert(:completed, "ISS-COMPLETED", now_ms + 1_000)
    assert :ok = EphemeralStore.upsert(:claimed, "ISS-EXPIRED", now_ms - 1)

    assert {:ok, entries} = EphemeralStore.list_active(now_ms)

    assert %{issue_id: "ISS-CLAIMED", kind: :claimed} =
             Enum.find(entries, &(&1.issue_id == "ISS-CLAIMED"))

    assert %{issue_id: "ISS-COMPLETED", kind: :completed} =
             Enum.find(entries, &(&1.issue_id == "ISS-COMPLETED"))

    refute Enum.any?(entries, &(&1.issue_id == "ISS-EXPIRED"))

    assert :ok = EphemeralStore.delete(:claimed, "ISS-CLAIMED")
    assert {:ok, remaining} = EphemeralStore.list_active(now_ms)
    refute Enum.any?(remaining, &(&1.issue_id == "ISS-CLAIMED"))
  end

  test "orchestrator prunes stale restored claimed marker and dispatches on poll", _context do
    issue =
      issue("ISS-CLAIM-RESTORE", "ABC-CLAIM-RESTORE", 1)
      |> Map.put(:state, "open")

    now_ms = System.monotonic_time(:millisecond)

    assert :ok = EphemeralStore.upsert(:claimed, issue.id, now_ms + 5_000)

    test_pid = self()
    tracker = fn _config -> {:ok, [issue]} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    agent_pool = start_supervised!({Kollywood.AgentPool, name: nil})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config_fixture(),
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_store: nil,
         ephemeral_store: EphemeralStore,
         agent_pool: agent_pool,
         claim_ttl_ms: 200,
         completed_ttl_ms: 200,
         repo_sync_interval_ms: 60_000}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-CLAIM-RESTORE"}, 1_000

    :ok = GenServer.stop(orchestrator)
  end

  test "poll reconciliation prunes stale open claims in memory and persisted store", _context do
    issue =
      issue("ISS-CLAIM-PRUNE", "ABC-CLAIM-PRUNE", 1)
      |> Map.put(:state, "open")
      |> Map.put(:blocked_by, [%{id: "ISS-BLOCKER", state: "open"}])

    test_pid = self()
    tracker = fn _config -> {:ok, [issue]} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    agent_pool = start_supervised!({Kollywood.AgentPool, name: nil})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config_fixture(),
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_store: nil,
         ephemeral_store: EphemeralStore,
         agent_pool: agent_pool,
         claim_ttl_ms: 5_000,
         completed_ttl_ms: 200,
         repo_sync_interval_ms: 60_000}
      )

    now_ms = System.monotonic_time(:millisecond)
    assert :ok = EphemeralStore.upsert(:claimed, issue.id, now_ms + 5_000)

    :sys.replace_state(orchestrator, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, issue.id),
          claimed_until: Map.put(state.claimed_until, issue.id, now_ms + 5_000)
      }
    end)

    assert [issue.id] == Orchestrator.status(orchestrator).claimed_issue_ids
    assert :ok = Orchestrator.poll_now(orchestrator)

    refute_receive {:runner_started, "ISS-CLAIM-PRUNE"}, 100
    assert [] == Orchestrator.status(orchestrator).claimed_issue_ids

    assert {:ok, entries} = EphemeralStore.list_active(System.monotonic_time(:millisecond))
    refute Enum.any?(entries, &(&1.issue_id == issue.id and &1.kind == :claimed))

    :ok = GenServer.stop(orchestrator)
  end

  test "orchestrator restores completed marker and dispatches after ttl", _context do
    issue = issue("ISS-COMPLETE-RESTORE", "ABC-COMPLETE-RESTORE", 1)
    now_ms = System.monotonic_time(:millisecond)

    assert :ok = EphemeralStore.upsert(:completed, issue.id, now_ms + 1_000)

    test_pid = self()
    tracker = fn _config -> {:ok, [issue]} end

    runner = fn issue, _opts ->
      send(test_pid, {:runner_started, issue.id})
      {:ok, success_result(issue)}
    end

    agent_pool = start_supervised!({Kollywood.AgentPool, name: nil})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         name: unique_name(:orchestrator),
         workflow_store: config_fixture(),
         tracker: tracker,
         runner: runner,
         auto_poll: false,
         retry_store: nil,
         ephemeral_store: EphemeralStore,
         agent_pool: agent_pool,
         claim_ttl_ms: 200,
         completed_ttl_ms: 1_000,
         repo_sync_interval_ms: 60_000}
      )

    assert :ok = Orchestrator.poll_now(orchestrator)
    refute_receive {:runner_started, "ISS-COMPLETE-RESTORE"}, 200

    Process.sleep(1_050)
    assert :ok = Orchestrator.poll_now(orchestrator)
    assert_receive {:runner_started, "ISS-COMPLETE-RESTORE"}, 1_000

    :ok = GenServer.stop(orchestrator)
  end

  defp config_fixture do
    %Config{
      tracker: %{
        active_states: ["Todo", "In Progress", "open"],
        terminal_states: ["Done", "Cancelled"]
      },
      polling: %{interval_ms: 1_000},
      workspace: %{
        root: Path.join(System.tmp_dir!(), "kollywood_test_workspaces"),
        strategy: :clone
      },
      hooks: %{},
      checks: %{},
      runtime: %{},
      review: %{},
      agent: %{
        kind: :amp,
        max_concurrent_agents: 1,
        max_turns: 1,
        retries_enabled: true,
        max_attempts: 5,
        max_retry_backoff_ms: 1_000,
        claim_ttl_ms: 200,
        completed_ttl_ms: 200
      },
      publish: %{},
      git: %{base_branch: "main"},
      raw: %{}
    }
  end

  defp issue(id, identifier, priority) do
    %{
      id: id,
      identifier: identifier,
      title: "Issue #{identifier}",
      description: "Ephemeral issue",
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

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive, :monotonic])}")
  end
end
