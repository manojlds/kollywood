defmodule Kollywood.Orchestrator.RunPhaseTest do
  use ExUnit.Case, async: true

  alias Kollywood.Orchestrator.RunPhase

  describe "from_events/2" do
    test "derives agent turn phase" do
      phase =
        RunPhase.from_events([
          %{type: :run_started},
          %{type: :turn_started, turn: 2}
        ])

      assert phase.kind == "agent"
      assert phase.turn == 2
      assert phase.label == "Agent turn 2"
    end

    test "derives checks counters with check count" do
      phase =
        RunPhase.from_events([
          %{type: :checks_started, check_count: 2},
          %{type: :check_started, check_index: 1}
        ])

      assert phase.kind == "checks"
      assert phase.check_index == 1
      assert phase.check_count == 2
      assert phase.label == "Checks 1/2"
    end

    test "derives review cycle phase" do
      phase = RunPhase.from_events([%{type: :review_started, cycle: 2}])

      assert phase.kind == "review"
      assert phase.review_cycle == 2
      assert phase.label == "Review cycle 2"
    end

    test "derives publish phase" do
      phase = RunPhase.from_events([%{type: :publish_started}])

      assert phase.kind == "publish"
      assert phase.label == "Publishing"
    end

    test "falls back to last known phase on unknown event" do
      phase =
        RunPhase.from_events([
          %{type: :check_started, check_index: 1, check_count: 2},
          %{type: :some_unknown_event}
        ])

      assert phase.kind == "checks"
      assert phase.label == "Checks 1/2"
    end

    test "derives failed terminal phase" do
      phase = RunPhase.from_events([%{type: :publish_failed}])

      assert phase.kind == "failed"
      assert phase.label == "Publishing failed"
    end

    test "keeps last known phase when a recognized stale event arrives later" do
      phase =
        RunPhase.from_events([
          %{type: :checks_started, check_count: 2, timestamp: ~U[2026-01-01 00:00:02Z]},
          %{type: :check_started, check_index: 1, timestamp: ~U[2026-01-01 00:00:03Z]},
          %{type: :turn_started, turn: 1, timestamp: ~U[2026-01-01 00:00:01Z]}
        ])

      assert phase.kind == "checks"
      assert phase.check_index == 1
      assert phase.check_count == 2
      assert phase.label == "Checks 1/2"
      assert phase.event_type == "check_started"
    end

    test "compares ISO8601 timestamps when resolving out-of-order events" do
      phase =
        RunPhase.from_events([
          %{type: :review_started, cycle: 2, timestamp: "2026-01-01T00:00:05Z"},
          %{
            type: :check_started,
            check_index: 2,
            check_count: 2,
            timestamp: "2026-01-01T00:00:04Z"
          }
        ])

      assert phase.kind == "review"
      assert phase.review_cycle == 2
      assert phase.label == "Review cycle 2"
      assert phase.event_type == "review_started"
    end
  end

  describe "from_status/2" do
    test "keeps last known phase when status is running" do
      known = %{kind: "agent", label: "Agent turn 3", turn: 3}
      phase = RunPhase.from_status("running", known)

      assert phase == known
    end

    test "maps terminal status to finished" do
      phase = RunPhase.from_status("finished")

      assert phase.kind == "finished"
      assert phase.label == "Run finished"
    end
  end
end
