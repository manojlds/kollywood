defmodule Kollywood.Orchestrator.RetryStoreTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator
  alias Kollywood.Orchestrator.RetryStore

  setup do
    assert :ok = RetryStore.clear()
    :ok
  end

  test "persists and restores retry entries" do
    issue_id = "ISS-RETRY-1"

    retry_entry = %{
      issue: %{id: issue_id, identifier: "ABC-RETRY-1", state: "Todo", title: "Retry"},
      attempt: 2,
      reason: "forced",
      kind: :finalize_done,
      finalization: %{done_metadata: %{status: :ok, turn_count: 1}},
      due_at_ms: System.monotonic_time(:millisecond) + 1_000
    }

    assert :ok = RetryStore.upsert(issue_id, retry_entry)

    assert {:ok, [stored]} = RetryStore.list()
    assert stored.issue_id == issue_id
    assert stored.attempt == 2
    assert stored.reason == "forced"
    assert stored.kind == :finalize_done
    assert stored.issue.id == issue_id
    assert stored.finalization.done_metadata.status == :ok

    assert :ok = RetryStore.delete(issue_id)
    assert {:ok, []} = RetryStore.list()
  end

  test "orchestrator restores persisted retries and dispatches without poll" do
    issue = issue("ISS-RETRY-RESTORE", "ABC-RETRY-RESTORE", 1)

    retry_entry = %{
      issue: issue,
      attempt: 1,
      reason: "restore",
      kind: :run,
      due_at_ms: System.monotonic_time(:millisecond)
    }

    assert :ok = RetryStore.upsert(issue.id, retry_entry)

    test_pid = self()

    tracker = fn _config ->
      {:ok, [issue]}
    end

    runner = fn issue, opts ->
      send(test_pid, {:runner_started, issue.id, Keyword.get(opts, :attempt)})
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
         retry_store: RetryStore,
         agent_pool: agent_pool,
         repo_sync_interval_ms: 60_000}
      )

    assert_receive {:runner_started, "ISS-RETRY-RESTORE", 1}, 1_000

    assert_retry_store_empty!()

    :ok = GenServer.stop(orchestrator)
  end

  defp assert_retry_store_empty!(attempts_left \\ 20)

  defp assert_retry_store_empty!(attempts_left) when attempts_left <= 0 do
    assert {:ok, []} = RetryStore.list()
  end

  defp assert_retry_store_empty!(attempts_left) do
    case RetryStore.list() do
      {:ok, []} ->
        :ok

      {:ok, _entries} ->
        Process.sleep(20)
        assert_retry_store_empty!(attempts_left - 1)
    end
  end

  defp config_fixture do
    %Config{
      tracker: %{
        active_states: ["Todo", "In Progress"],
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
        max_retry_backoff_ms: 1_000
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
      description: "Retry issue",
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
