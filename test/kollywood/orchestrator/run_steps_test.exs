defmodule Kollywood.Orchestrator.RunStepsTest do
  use ExUnit.Case, async: true

  alias Kollywood.Orchestrator.RunSteps

  describe "from_events/2" do
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
  end
end
