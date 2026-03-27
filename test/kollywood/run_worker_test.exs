defmodule Kollywood.RunWorkerTest do
  use ExUnit.Case, async: true

  alias Kollywood.RunWorker

  test "reports run results to orchestrator" do
    test_pid = self()

    assert {:ok, run_pid} =
             RunWorker.start_link(
               orchestrator: test_pid,
               issue_id: "ISS-42",
               run_fun: fn -> {:ok, :done} end
             )

    assert_receive {:run_worker_result, "ISS-42", ^run_pid, {:ok, :done}}, 1_000

    ref = Process.monitor(run_pid)
    assert_receive {:DOWN, ^ref, :process, ^run_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end
end
