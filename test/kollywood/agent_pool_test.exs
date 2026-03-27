defmodule Kollywood.AgentPoolTest do
  use ExUnit.Case, async: true

  alias Kollywood.AgentPool

  test "starts run workers through the dedicated pool" do
    {:ok, pool} = AgentPool.start_link(name: nil)
    test_pid = self()

    assert {:ok, run_pid} =
             AgentPool.start_run(pool,
               orchestrator: test_pid,
               issue_id: "ISS-1",
               run_fun: fn -> :ok end
             )

    assert is_pid(run_pid)

    assert_receive {:run_worker_result, "ISS-1", ^run_pid, :ok}, 1_000
  end
end
