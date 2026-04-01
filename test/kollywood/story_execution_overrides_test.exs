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
                 "review_max_cycles" => "3",
                 "testing_enabled" => "true",
                 "preview_enabled" => true,
                 "testing_agent_kind" => "opencode",
                 "testing_max_cycles" => "2"
               }
             })

    assert normalized == %{
             "execution" => %{
               "agent_kind" => "cursor",
               "review_agent_kind" => "claude",
               "review_max_cycles" => 3,
               "testing_enabled" => true,
               "preview_enabled" => true,
               "testing_agent_kind" => "opencode",
               "testing_max_cycles" => 2
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
          "review_max_cycles" => 9,
          "testing_enabled" => true,
          "preview_enabled" => true,
          "testing_agent_kind" => "opencode",
          "testing_max_cycles" => 10
        }
      }
    }

    assert {:ok, resolved} = StoryExecutionOverrides.resolve(base_config(), issue)

    assert resolved.config.agent.kind == :cursor
    assert resolved.config.review.agent.kind == :claude
    assert resolved.config.review.agent.explicit == true
    assert resolved.config.review.max_cycles == 2
    assert resolved.config.quality.review.max_cycles == 2
    assert resolved.config.testing.enabled == true
    assert resolved.config.preview.enabled == true
    assert resolved.config.testing.agent.kind == :opencode
    assert resolved.config.testing.agent.explicit == true
    assert resolved.config.testing.max_cycles == 2
    assert resolved.config.quality.testing.max_cycles == 2

    assert resolved.settings_snapshot["agent_kind"] == "cursor"
    assert resolved.settings_snapshot["review_agent_kind"] == "claude"
    assert resolved.settings_snapshot["review_max_cycles"] == 2
    assert resolved.settings_snapshot["testing_enabled"] == true
    assert resolved.settings_snapshot["preview_enabled"] == true
    assert resolved.settings_snapshot["testing_agent_kind"] == "opencode"
    assert resolved.settings_snapshot["testing_max_cycles"] == 2
    assert resolved.settings_snapshot["story_overrides"]["review_max_cycles"] == 9
    assert resolved.settings_snapshot["story_overrides"]["testing_max_cycles"] == 10
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

  test "rejects invalid testing_enabled override values" do
    issue = %{
      id: "US-125",
      identifier: "US-125",
      settings: %{"execution" => %{"testing_enabled" => "definitely"}}
    }

    assert {:error, reason} = StoryExecutionOverrides.resolve(base_config(), issue)
    assert reason =~ "testing_enabled"
    assert reason =~ "boolean"
  end

  test "defaults testing_enabled to false unless story opts in" do
    issue = %{id: "US-126", identifier: "US-126", settings: %{"execution" => %{}}}

    config =
      base_config()
      |> Map.put(:testing, %{enabled: true, max_cycles: 1, agent: %{kind: :amp, explicit: false}})
      |> Map.put(:quality, %{
        max_cycles: 2,
        review: %{max_cycles: 1, agent: %{kind: :amp, explicit: false}},
        testing: %{enabled: true, max_cycles: 1, agent: %{kind: :amp, explicit: false}}
      })

    assert {:ok, resolved} = StoryExecutionOverrides.resolve(config, issue)
    assert resolved.config.testing.enabled == false
    assert resolved.config.quality.testing.enabled == false
    assert resolved.settings_snapshot["testing_enabled"] == false
  end

  defp base_config do
    %Config{
      quality: %{
        max_cycles: 2,
        review: %{
          max_cycles: 1,
          agent: %{kind: :amp, explicit: false}
        },
        testing: %{
          enabled: false,
          max_cycles: 1,
          timeout_ms: 10_000,
          prompt_template: nil,
          agent: %{kind: :amp, explicit: false}
        }
      },
      review: %{
        enabled: true,
        max_cycles: 1,
        agent: %{kind: :amp, explicit: false}
      },
      testing: %{
        enabled: false,
        max_cycles: 1,
        timeout_ms: 10_000,
        prompt_template: nil,
        agent: %{kind: :amp, explicit: false}
      },
      preview: %{
        enabled: false,
        ttl_minutes: 120,
        reuse_testing_runtime: true,
        allow_on_demand_from_pending_merge: true,
        start_timeout_ms: 120_000,
        stop_timeout_ms: 60_000
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
      runtime: %{
        kind: :host,
        command: "pitchfork",
        processes: [],
        env: %{},
        ports: %{},
        port_offset_mod: 1000,
        start_timeout_ms: 120_000,
        stop_timeout_ms: 60_000
      },
      publish: %{},
      git: %{},
      raw: %{}
    }
  end
end
