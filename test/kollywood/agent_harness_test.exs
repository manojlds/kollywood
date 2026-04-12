defmodule Kollywood.AgentHarnessTest do
  use ExUnit.Case, async: true

  alias Kollywood.AgentHarness
  alias Kollywood.Config

  test "review profile separates role from harness" do
    config =
      base_config()
      |> Map.put(:review, %{
        enabled: true,
        max_cycles: 2,
        prompt_template: "Review {{ issue.identifier }}",
        agent: %{
          explicit: true,
          kind: :codex,
          model: "o3",
          command: "/usr/local/bin/reviewer",
          args: ["--print"],
          env: %{"REVIEW_MODE" => "strict"},
          timeout_ms: 12_000
        }
      })

    profile = AgentHarness.resolve(config, :review)

    assert profile.phase == :review
    assert profile.role.kind == :codex
    assert profile.role.max_turns == 1
    assert profile.role.max_cycles == 2
    assert profile.role.enabled == true
    assert profile.role.explicit == true

    assert profile.harness.command == "/usr/local/bin/reviewer"
    assert profile.harness.model == "o3"
    assert profile.harness.args == ["--print"]
    assert profile.harness.env["BASE"] == "1"
    assert profile.harness.env["REVIEW_MODE"] == "strict"
    assert profile.harness.timeout_ms == 12_000

    assert profile.session_config.agent.kind == :codex
    assert profile.session_config.agent.max_turns == 1
    assert profile.session_config.agent.model == "o3"
    assert profile.session_config.agent.command == "/usr/local/bin/reviewer"
  end

  test "testing profile merges runtime env into harness env" do
    config =
      base_config()
      |> Map.put(:testing, %{
        enabled: true,
        max_cycles: 2,
        timeout_ms: 45_000,
        prompt_template: "Test {{ issue.identifier }}",
        agent: %{
          explicit: true,
          kind: :cursor,
          model: "cursor-fast",
          command: "/usr/local/bin/tester",
          args: ["--json"],
          env: %{"TEST_MODE" => "smoke"},
          timeout_ms: 22_000
        }
      })

    profile =
      AgentHarness.resolve(config, :testing,
        runtime_env: %{
          "KOLLYWOOD_RUNTIME_BASE_URL" => "http://127.0.0.1:4100",
          "KOLLYWOOD_URL_APP" => "http://127.0.0.1:4100"
        }
      )

    assert profile.phase == :testing
    assert profile.role.kind == :cursor
    assert profile.role.max_turns == 1
    assert profile.role.timeout_ms == 45_000
    assert profile.role.explicit == true

    assert profile.harness.env["BASE"] == "1"
    assert profile.harness.env["TEST_MODE"] == "smoke"
    assert profile.harness.env["KOLLYWOOD_RUNTIME_BASE_URL"] == "http://127.0.0.1:4100"
    assert profile.harness.env["KOLLYWOOD_URL_APP"] == "http://127.0.0.1:4100"

    assert profile.session_config.agent.kind == :cursor
    assert profile.session_config.agent.max_turns == 1
    assert profile.session_config.agent.model == "cursor-fast"
    assert profile.session_config.agent.command == "/usr/local/bin/tester"
  end

  defp base_config do
    %Config{
      tracker: %{},
      polling: %{},
      workspace: %{root: "/tmp", strategy: :clone},
      hooks: %{},
      quality: %{max_cycles: 3},
      checks: %{},
      runtime: %{},
      review: %{},
      testing: %{},
      preview: %{},
      agent: %{
        kind: :opencode,
        max_concurrent_agents: 1,
        max_turns: 5,
        completion_signals: ["DONE"],
        idle_timeout_ms: 5_000,
        command: "/usr/local/bin/opencode",
        model: "gpt-5",
        args: ["--fast"],
        env: %{"BASE" => "1"},
        timeout_ms: 90_000
      },
      publish: %{},
      git: %{},
      raw: %{}
    }
  end
end
