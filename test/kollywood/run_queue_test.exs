defmodule Kollywood.RunQueueTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kollywood.Repo
  alias Kollywood.RunQueue
  alias Kollywood.RunQueue.Entry

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "enqueue/1" do
    test "creates a pending entry" do
      assert {:ok, entry} =
               RunQueue.enqueue(%{
                 issue_id: "issue-1",
                 identifier: "US-001"
               })

      assert entry.status == "pending"
      assert entry.issue_id == "issue-1"
      assert entry.identifier == "US-001"
      assert entry.priority == 0
    end

    test "accepts optional fields" do
      assert {:ok, entry} =
               RunQueue.enqueue(%{
                 issue_id: "issue-2",
                 identifier: "US-002",
                 project_slug: "kollywood",
                 priority: 5,
                 attempt: 2,
                 config_snapshot: ~s({"key":"value"})
               })

      assert entry.priority == 5
      assert entry.attempt == 2
      assert entry.project_slug == "kollywood"
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = RunQueue.enqueue(%{issue_id: "x"})
      assert %{identifier: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "claim/2" do
    test "claims oldest pending entry" do
      {:ok, _e1} = RunQueue.enqueue(%{issue_id: "a", identifier: "US-A"})
      {:ok, _e2} = RunQueue.enqueue(%{issue_id: "b", identifier: "US-B"})

      assert {:ok, claimed} = RunQueue.claim("node-1")
      assert claimed.issue_id == "a"
      assert claimed.status == "claimed"
      assert claimed.claimed_by_node == "node-1"
      assert is_binary(claimed.lease_token)
      assert claimed.claimed_at != nil
    end

    test "returns :none when queue is empty" do
      assert :none = RunQueue.claim("node-1")
    end

    test "does not reclaim already claimed entries" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "a", identifier: "US-A"})
      {:ok, _} = RunQueue.claim("node-1")

      assert :none = RunQueue.claim("node-2")
    end

    test "higher priority entries are claimed first" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "low", identifier: "US-L", priority: 1})
      {:ok, _} = RunQueue.enqueue(%{issue_id: "high", identifier: "US-H", priority: 10})

      assert {:ok, claimed} = RunQueue.claim("node-1")
      assert claimed.issue_id == "high"
    end
  end

  describe "claim_batch/2" do
    test "claims up to N entries" do
      for i <- 1..5 do
        RunQueue.enqueue(%{issue_id: "i-#{i}", identifier: "US-#{i}"})
      end

      entries = RunQueue.claim_batch("node-1", 3)
      assert length(entries) == 3
    end

    test "returns fewer if not enough pending" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "only", identifier: "US-1"})
      entries = RunQueue.claim_batch("node-1", 5)
      assert length(entries) == 1
    end
  end

  describe "mark_running/1" do
    test "sets claimed entries to running" do
      {:ok, entry} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      assert {:ok, _claimed} = RunQueue.claim("node-1")
      assert {:ok, updated} = RunQueue.mark_running(entry.id)
      assert updated.status == "running"
      assert updated.started_at != nil
    end
  end

  describe "worker-owned transitions" do
    test "worker can move its claimed entry to running" do
      {:ok, _entry} = RunQueue.enqueue(%{issue_id: "owned", identifier: "US-OWNED"})
      assert {:ok, claimed} = RunQueue.claim("worker-1")

      assert {:ok, running} =
               RunQueue.mark_running_for_worker(claimed.id, "worker-1", claimed.lease_token)

      assert running.status == "running"
      assert running.claimed_by_node == "worker-1"
      assert running.last_heartbeat_at != nil
    end

    test "another worker cannot complete a leased entry it does not own" do
      {:ok, _entry} = RunQueue.enqueue(%{issue_id: "conflict", identifier: "US-CONFLICT"})
      assert {:ok, claimed} = RunQueue.claim("worker-1")

      assert {:error, :conflict} =
               RunQueue.complete_for_worker(claimed.id, "worker-2", claimed.lease_token, %{
                 result_payload: %{status: "ok"}
               })
    end

    test "same worker cannot advance a run with the wrong lease token" do
      {:ok, _entry} = RunQueue.enqueue(%{issue_id: "wrong-token", identifier: "US-WRONG"})
      assert {:ok, claimed} = RunQueue.claim("worker-1")

      assert {:error, :conflict} =
               RunQueue.mark_running_for_worker(claimed.id, "worker-1", Ecto.UUID.generate())
    end
  end

  describe "complete/2" do
    test "marks active entry as completed with payload" do
      {:ok, entry} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      assert {:ok, _claimed} = RunQueue.claim("node-1")
      assert {:ok, _running} = RunQueue.mark_running(entry.id)
      assert {:ok, updated} = RunQueue.complete(entry.id, %{result_payload: %{"status" => "ok"}})
      assert updated.status == "completed"
      assert updated.completed_at != nil
    end
  end

  describe "fail/2" do
    test "marks active entry as failed" do
      {:ok, entry} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      assert {:ok, _claimed} = RunQueue.claim("node-1")
      assert {:ok, _running} = RunQueue.mark_running(entry.id)
      assert {:ok, updated} = RunQueue.fail(entry.id, "something broke")
      assert updated.status == "failed"
      assert updated.error == "something broke"
    end
  end

  describe "fail_running_for_node/2" do
    test "marks running entries for one node as failed" do
      {:ok, entry_a} = RunQueue.enqueue(%{issue_id: "node-a", identifier: "US-A"})
      {:ok, entry_b} = RunQueue.enqueue(%{issue_id: "node-b", identifier: "US-B"})

      assert {:ok, _} = RunQueue.claim("node-1")
      assert {:ok, _} = RunQueue.claim("node-2")

      assert {:ok, _} = RunQueue.mark_running(entry_a.id)
      assert {:ok, _} = RunQueue.mark_running(entry_b.id)

      count = RunQueue.fail_running_for_node("node-1", "startup recovery")
      assert count == 1

      refreshed_a = RunQueue.get(entry_a.id)
      refreshed_b = RunQueue.get(entry_b.id)

      assert refreshed_a.status == "failed"
      assert refreshed_a.error == "startup recovery"
      assert refreshed_b.status == "running"
    end
  end

  describe "cancel/1" do
    test "marks entry as cancelled" do
      {:ok, entry} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      assert {:ok, updated} = RunQueue.cancel(entry.id)
      assert updated.status == "cancelled"
    end
  end

  describe "queries" do
    test "list_pending returns only pending entries" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "a", identifier: "US-A"})
      {:ok, _} = RunQueue.enqueue(%{issue_id: "b", identifier: "US-B"})
      RunQueue.claim("node-1")

      pending = RunQueue.list_pending()
      assert length(pending) == 1
      assert hd(pending).issue_id == "b"
    end

    test "list_by_status filters correctly" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "a", identifier: "US-A"})
      {:ok, e2} = RunQueue.enqueue(%{issue_id: "b", identifier: "US-B"})
      RunQueue.claim("node-1")
      RunQueue.claim("node-2")
      RunQueue.mark_running(e2.id)
      RunQueue.fail(e2.id, "error")

      failed = RunQueue.list_by_status("failed")
      assert length(failed) == 1
      assert hd(failed).issue_id == "b"
    end

    test "pending_count" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "a", identifier: "US-A"})
      {:ok, _} = RunQueue.enqueue(%{issue_id: "b", identifier: "US-B"})
      assert RunQueue.pending_count() == 2
    end

    test "get_by_issue returns active entry for issue" do
      {:ok, _} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      assert entry = RunQueue.get_by_issue("x")
      assert entry.issue_id == "x"
    end

    test "get_by_issue returns nil for completed issues" do
      {:ok, e} = RunQueue.enqueue(%{issue_id: "x", identifier: "US-X"})
      RunQueue.claim("node-1")
      RunQueue.mark_running(e.id)
      RunQueue.complete(e.id)
      assert RunQueue.get_by_issue("x") == nil
    end
  end

  describe "reclaim_stale/1" do
    test "reclaims entries claimed longer than threshold" do
      {:ok, _entry} = RunQueue.enqueue(%{issue_id: "stale", identifier: "US-S"})
      {:ok, claimed} = RunQueue.claim("node-1")

      old_time = DateTime.add(DateTime.utc_now(), -700, :second)
      claimed_id = claimed.id

      Repo.update_all(
        from(e in Entry, where: e.id == ^claimed_id),
        set: [claimed_at: old_time, last_heartbeat_at: old_time]
      )

      count = RunQueue.reclaim_stale(600_000)
      assert count == 1

      refreshed = RunQueue.get(claimed.id)
      assert refreshed.status == "pending"
      assert refreshed.claimed_by_node == nil
    end

    test "reclaims running entries with stale heartbeats" do
      {:ok, _entry} = RunQueue.enqueue(%{issue_id: "running-stale", identifier: "US-RUN-ST"})
      assert {:ok, claimed} = RunQueue.claim("worker-1")

      assert {:ok, _running} =
               RunQueue.mark_running_for_worker(claimed.id, "worker-1", claimed.lease_token)

      old_time = DateTime.add(DateTime.utc_now(), -700, :second)

      Repo.update_all(
        from(e in Entry, where: e.id == ^claimed.id),
        set: [last_heartbeat_at: old_time]
      )

      count = RunQueue.reclaim_stale(600_000)
      assert count == 1

      refreshed = RunQueue.get(claimed.id)
      assert refreshed.status == "pending"
      assert refreshed.claimed_by_node == nil
      assert refreshed.started_at == nil
    end
  end

  describe "prune_completed/1" do
    test "removes old completed entries" do
      {:ok, e} = RunQueue.enqueue(%{issue_id: "old", identifier: "US-O"})
      RunQueue.claim("node-1")
      RunQueue.mark_running(e.id)
      RunQueue.complete(e.id)

      old_time = DateTime.add(DateTime.utc_now(), -100_000, :second)
      entry_id = e.id

      Repo.update_all(
        from(e in Entry, where: e.id == ^entry_id),
        set: [completed_at: old_time]
      )

      count = RunQueue.prune_completed(86_400_000)
      assert count == 1
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
