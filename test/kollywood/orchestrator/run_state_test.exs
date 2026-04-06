defmodule Kollywood.Orchestrator.RunStateTest do
  use ExUnit.Case, async: true

  alias Kollywood.Orchestrator.RunState

  test "from_status maps running lifecycle" do
    state = RunState.from_status(:running)
    assert state.phase == "running"
    assert state.activity == "idle"
  end

  test "from_event marks execution activity" do
    state = RunState.from_status(:running)
    next = RunState.from_event(%{type: :check_started, check_index: 1, check_count: 2}, state)

    assert next.phase == "running"
    assert next.activity == "executing"
    assert next.detail.check_index == 1
    assert next.detail.check_count == 2
    assert next.detail.last_event_type == "check_started"
  end

  test "sticky completed is preserved until new work starts" do
    done = RunState.from_event(%{type: :completion_detected}, RunState.from_status(:running))
    assert done.activity == "completed"

    noisy = RunState.from_event(%{type: :runtime_started}, done)
    assert noisy.activity == "completed"

    resumed = RunState.from_event(%{type: :turn_started, turn: 2}, noisy)
    assert resumed.activity == "executing"
  end

  test "health downgrade eligibility excludes terminal sticky states" do
    blocked = RunState.from_status(:failed)
    assert RunState.eligible_for_health_downgrade?(blocked) == false

    completed = RunState.from_status(:completed)
    assert RunState.eligible_for_health_downgrade?(completed) == false

    running = RunState.from_status(:running)
    assert RunState.eligible_for_health_downgrade?(running) == true

    stalled = RunState.from_status(:stalled)
    assert RunState.eligible_for_health_downgrade?(stalled) == true
  end

  test "progress_event detects runner progress events" do
    assert RunState.progress_event?(%{type: :turn_started})
    assert RunState.progress_event?(%{"type" => "runtime_started"})
    refute RunState.progress_event?(%{type: :unknown_event})
  end
end
