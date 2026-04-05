defmodule Kollywood.Orchestrator.RunStepsTest do
  use ExUnit.Case, async: true

  alias Kollywood.Orchestrator.RunSteps

  describe "from_events/2" do
    test "folds execution session lifecycle events into current agent turn" do
      steps =
        RunSteps.from_events([
          %{type: :turn_started, turn: 1},
          %{type: :execution_session_started, session_id: "exec-1"},
          %{type: :session_started, session_id: "legacy-1"},
          %{type: :turn_succeeded, turn: 1, output: "done"},
          %{type: :execution_session_completed, status: :ok},
          %{type: :session_stopped, session_id: "legacy-1"},
          %{type: :execution_session_stopped, session_id: "exec-1"},
          %{type: :run_finished, status: "ok"}
        ])

      agent_turn = Enum.find(steps, &(&1.kind == "agent_turn"))
      assert agent_turn

      event_types =
        Enum.map(agent_turn.events, fn event ->
          to_string(Map.get(event, :type) || Map.get(event, "type"))
        end)

      assert "execution_session_started" in event_types
      assert "execution_session_completed" in event_types
      assert "execution_session_stopped" in event_types
      assert "session_started" in event_types
      assert "session_stopped" in event_types
    end

    test "carries agent prompt when prompt event follows a completed marker step" do
      steps =
        RunSteps.from_events([
          %{type: :quality_cycle_started, cycle: 1},
          %{type: :prompt_captured, phase: :agent, prompt: "Agent first prompt"},
          %{type: :turn_started, turn: 1},
          %{type: :turn_succeeded, turn: 1, output: "done"}
        ])

      assert Enum.any?(
               steps,
               &(&1.kind == "prompt_captured" and &1.prompt == "Agent first prompt")
             )

      assert Enum.any?(steps, &(&1.kind == "agent_turn" and &1.prompt == "Agent first prompt"))
    end

    test "captures prompts emitted after review/testing steps start" do
      steps =
        RunSteps.from_events([
          %{type: :review_started, cycle: 1},
          %{type: :prompt_captured, phase: :review, prompt: "Review first prompt"},
          %{type: :review_passed, cycle: 1},
          %{type: :testing_started, cycle: 1},
          %{type: :prompt_captured, phase: :testing, prompt: "Testing first prompt"},
          %{type: :testing_passed, cycle: 1}
        ])

      assert Enum.any?(steps, &(&1.kind == "review" and &1.prompt == "Review first prompt"))
      assert Enum.any?(steps, &(&1.kind == "testing" and &1.prompt == "Testing first prompt"))
    end

    test "keeps completion_detected event attached to current agent turn" do
      steps =
        RunSteps.from_events([
          %{type: :turn_started, turn: 1},
          %{type: :turn_succeeded, turn: 1, output: "done"},
          %{type: :completion_detected, signal: "DONE_SIGNAL"},
          %{type: :run_finished, status: "completed"}
        ])

      agent_turn = Enum.find(steps, &(&1.kind == "agent_turn"))
      assert agent_turn

      assert Enum.any?(agent_turn.events, fn event ->
               to_string(Map.get(event, :type) || Map.get(event, "type")) == "completion_detected"
             end)
    end

    test "keeps idle_timeout_reached event attached to current agent turn" do
      steps =
        RunSteps.from_events([
          %{type: :turn_started, turn: 1},
          %{type: :idle_timeout_reached, reason: "timeout"},
          %{type: :turn_failed, turn: 1, reason: "idle timeout"},
          %{type: :run_finished, status: "failed"}
        ])

      agent_turn = Enum.find(steps, &(&1.kind == "agent_turn"))
      assert agent_turn

      assert Enum.any?(agent_turn.events, fn event ->
               to_string(Map.get(event, :type) || Map.get(event, "type")) ==
                 "idle_timeout_reached"
             end)
    end

    test "captures structured recovery guidance on failed publish steps" do
      steps =
        RunSteps.from_events([
          %{type: :publish_started, mode: "push", branch: "kw/US-RECOVERY-STEP"},
          %{
            type: :publish_failed,
            reason:
              "push failed\nRecovery commands:\n  git -C '/tmp/work' status --short\n  git -C '/tmp/work' push -u origin 'kw/US-RECOVERY-STEP'"
          },
          %{type: :run_finished, status: "failed"}
        ])

      publish_step = Enum.find(steps, &(&1.kind == "publish"))
      assert publish_step

      assert publish_step.detail.recovery_guidance.summary == "push failed"

      assert publish_step.detail.recovery_guidance.commands == [
               "git -C '/tmp/work' status --short",
               "git -C '/tmp/work' push -u origin 'kw/US-RECOVERY-STEP'"
             ]
    end

    test "prefers structured recovery guidance payload when present" do
      steps =
        RunSteps.from_events([
          %{type: :publish_started, mode: "push", branch: "kw/US-RECOVERY-STRUCTURED"},
          %{
            type: :publish_failed,
            reason: "publish failed",
            recovery_guidance: %{
              summary: "publish failed",
              commands: [
                "git -C '/tmp/work' fetch --all --prune",
                "git -C '/tmp/work' push -u origin 'kw/US-RECOVERY-STRUCTURED'"
              ]
            }
          },
          %{type: :run_finished, status: "failed"}
        ])

      publish_step = Enum.find(steps, &(&1.kind == "publish"))
      assert publish_step

      assert publish_step.detail.recovery_guidance.summary == "publish failed"

      assert publish_step.detail.recovery_guidance.commands == [
               "git -C '/tmp/work' fetch --all --prune",
               "git -C '/tmp/work' push -u origin 'kw/US-RECOVERY-STRUCTURED'"
             ]
    end
  end
end
