defmodule Kollywood.StoryExecutionOverridesTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config
  alias Kollywood.StoryExecutionOverrides

  test "normalizes valid execution settings" do
    assert {:ok, normalized} =
             StoryExecutionOverrides.normalize_settings(%{
               "execution" => %{
                 "agent_kind" => "cursor",
                 "review_agent_kind" => "claude",
                 "review_max_cycles" => "3"
               }
             })

    assert normalized == %{
             "execution" => %{
               "agent_kind" => "cursor",
               "review_agent_kind" => "claude",
               "review_max_cycles" => 3
             }
           }
  end

  test "rejects unsupported execution override fields" do
    assert {:error, reason} =
             StoryExecutionOverrides.normalize_settings(%{
               "execution" => %{
                 "agent_kind" => "amp",
                 "unknown_field" => "value"
               }
             })

    assert reason =~ "unsupported fields"
    assert reason =~ "unknown_field"
  end

  test "resolves config with overrides and applies review cycle safety cap" do
    issue = %{
      id: "US-123",
      identifier: "US-123",
      settings: %{
        "execution" => %{
          "agent_kind" => "cursor",
          "review_agent_kind" => "claude",
          "review_max_cycles" => 9
        }
      }
    }

    assert {:ok, resolved} = StoryExecutionOverrides.resolve(base_config(), issue)

    assert resolved.config.agent.kind == :cursor
    assert resolved.config.review.agent.kind == :claude
    assert resolved.config.review.agent.explicit == true
    assert resolved.config.review.max_cycles == 2
    assert resolved.config.quality.review.max_cycles == 2

    assert resolved.settings_snapshot["agent_kind"] == "cursor"
    assert resolved.settings_snapshot["review_agent_kind"] == "claude"
    assert resolved.settings_snapshot["review_max_cycles"] == 2
    assert resolved.settings_snapshot["story_overrides"]["review_max_cycles"] == 9
  end

  test "rejects invalid override values" do
    issue = %{
      id: "US-124",
      identifier: "US-124",
      settings: %{"execution" => %{"review_max_cycles" => "zero"}}
    }

    assert {:error, reason} = StoryExecutionOverrides.resolve(base_config(), issue)
    assert reason =~ "review_max_cycles"
    assert reason =~ "positive integer"
  end

  defp base_config do
    %Config{
      quality: %{
        max_cycles: 2,
        review: %{
          max_cycles: 1,
          agent: %{kind: :amp, explicit: false}
        }
      },
      review: %{
        enabled: true,
        max_cycles: 1,
        agent: %{kind: :amp, explicit: false}
      },
      agent: %{
        kind: :amp,
        max_turns: 3,
        max_concurrent_agents: 1,
        retries_enabled: true,
        max_attempts: 1,
        max_retry_backoff_ms: 1000,
        command: "/bin/true",
        args: [],
        env: %{},
        timeout_ms: 10_000
      },
      workspace: %{root: "/tmp", strategy: :clone},
      tracker: %{},
      polling: %{},
      hooks: %{},
      checks: %{required: [], timeout_ms: 10_000, fail_fast: true},
      runtime: %{profile: :checks_only, full_stack: %{}},
      publish: %{},
      git: %{},
      raw: %{}
    }
  end
end
