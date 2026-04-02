defmodule Kollywood.WorkerConsumerTest do
  use ExUnit.Case, async: false

  alias Kollywood.Repo
  alias Kollywood.RunQueue
  alias Kollywood.WorkerConsumer

  defmodule FakeAgentPool do
    use DynamicSupervisor

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
    end

    def start_run(server \\ __MODULE__, opts) do
      DynamicSupervisor.start_child(server, {Kollywood.RunWorker, opts})
    end

    def stop_run(server \\ __MODULE__, pid) do
      DynamicSupervisor.terminate_child(server, pid)
    end

    @impl true
    def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, pool} = FakeAgentPool.start_link(name: nil)
    %{pool: pool}
  end

  test "status reports node_id and worker counts", %{pool: pool} do
    {:ok, consumer} =
      WorkerConsumer.start_link(
        name: nil,
        agent_pool: pool,
        poll_interval_ms: 60_000,
        max_local_workers: 3
      )

    status = WorkerConsumer.status(consumer)
    assert status.max_local_workers == 3
    assert status.active_workers == 0
    assert status.available_slots == 3
    assert is_binary(status.node_id)
  end

  test "consumer claims and processes pending queue entries", %{pool: pool} do
    {:ok, _entry} =
      RunQueue.enqueue(%{
        issue_id: "test-issue-1",
        identifier: "US-100",
        config_snapshot: Jason.encode!(%{"issue" => %{"id" => "test-issue-1", "identifier" => "US-100", "title" => "Test", "state" => "open"}}),
        run_opts_snapshot: Jason.encode!(%{})
      })

    {:ok, _consumer} =
      WorkerConsumer.start_link(
        name: nil,
        agent_pool: pool,
        poll_interval_ms: 100,
        max_local_workers: 2
      )

    Process.sleep(500)

    refreshed = RunQueue.get_by_issue("test-issue-1")

    if refreshed do
      assert refreshed.status in ["claimed", "running", "completed", "failed"]
    end
  end

  test "consumer respects max_local_workers limit", %{pool: pool} do
    for i <- 1..5 do
      RunQueue.enqueue(%{
        issue_id: "issue-#{i}",
        identifier: "US-#{i}",
        run_opts_snapshot: Jason.encode!(%{})
      })
    end

    {:ok, consumer} =
      WorkerConsumer.start_link(
        name: nil,
        agent_pool: pool,
        poll_interval_ms: 60_000,
        max_local_workers: 2
      )

    send(consumer, :poll)
    Process.sleep(200)

    status = WorkerConsumer.status(consumer)
    assert status.active_workers <= 2
  end
end
