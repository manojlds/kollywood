defmodule Kollywood.ConfigTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config

  import ExUnit.CaptureLog

  @valid_workflow """
  ---
  tracker:
    kind: linear
    project_slug: my-project
    active_states:
      - Todo
      - In Progress
    terminal_states:
      - Done
      - Cancelled
  polling:
    interval_ms: 3000
    stale_threshold_multiplier: 4
    watchdog_check_interval_ms: 750
  workspace:
    root: ~/workspaces
  agent:
    kind: amp
    max_concurrent_agents: 3
    project_max_concurrent_agents:
      alpha: 1
      beta: 2
    max_turns: 10
  ---

  You are working on {{ issue.identifier }}.
  """

  test "parses valid WORKFLOW.md content" do
    assert {:ok, config, template} = Config.parse(@valid_workflow)
    assert config.agent.kind == :amp
    assert config.agent.max_concurrent_agents == 3
    assert config.agent.project_max_concurrent_agents == %{"alpha" => 1, "beta" => 2}
    assert config.agent.max_turns == 10
    assert config.tracker.kind == "linear"
    assert config.tracker.project_slug == "my-project"
    assert config.tracker.active_states == ["Todo", "In Progress"]
    assert config.polling.interval_ms == 3000
    assert config.polling.stale_threshold_multiplier == 4
    assert config.polling.watchdog_check_interval_ms == 750
    assert config.workspace.root == "~/workspaces"
    assert template =~ "{{ issue.identifier }}"
  end

  test "supports all agent kinds" do
    for kind <- ~w(amp claude cursor opencode pi) do
      content = """
      ---
      workspace:
        root: /tmp
      agent:
        kind: #{kind}
      ---
      prompt
      """

      assert {:ok, config, _} = Config.parse(content)
      assert config.agent.kind == String.to_atom(kind)
    end
  end

  test "rejects invalid agent kind" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: invalid
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid agent.kind"
  end

  test "rejects missing agent.kind" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      max_turns: 5
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "agent.kind is required"
  end

  test "rejects missing front matter" do
    assert {:error, _} = Config.parse("just some markdown")
  end

  test "uses defaults for optional fields" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: claude
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.polling.interval_ms == 5000
    assert config.polling.stale_threshold_multiplier == 3
    assert config.polling.watchdog_check_interval_ms == 5000
    assert config.agent.max_concurrent_agents == 1
    assert config.agent.project_max_concurrent_agents == %{}
    assert config.agent.max_turns == 20
    assert config.agent.retries_enabled == false
    assert config.agent.max_retry_backoff_ms == 300_000
    assert config.agent.command == nil
    assert config.agent.args == []
    assert config.agent.env == %{}
    assert config.agent.timeout_ms == 7_200_000
    assert config.tracker.active_states == ["Todo", "In Progress"]

    assert config.publish.provider == nil
    assert config.publish.mode == nil
    assert config.publish.auto_push == :never
    assert config.publish.auto_merge == :never
    assert config.publish.auto_create_pr == :never

    assert config.git.base_branch == "main"

    assert config.project_provider == nil
    assert Config.effective_publish_provider(config) == nil
    assert Config.effective_publish_mode(config) == :push
  end

  test "parses optional agent runtime settings" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: opencode
      command: /usr/local/bin/opencode
      args:
        - --print
        - --json
      env:
        OPENAI_API_KEY: test-key
      timeout_ms: "90000"
      max_retry_backoff_ms: "120000"
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.agent.command == "/usr/local/bin/opencode"
    assert config.agent.args == ["--print", "--json"]
    assert config.agent.env == %{"OPENAI_API_KEY" => "test-key"}
    assert config.agent.timeout_ms == 90_000
    assert config.agent.max_retry_backoff_ms == 120_000
  end

  test "ignores invalid project max concurrent agent entries" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: amp
      project_max_concurrent_agents:
        alpha: 2
        beta: invalid
        gamma: 0
    ---
    prompt
    """

    log =
      capture_log(fn ->
        assert {:ok, config, _} = Config.parse(content)
        assert config.agent.project_max_concurrent_agents == %{"alpha" => 2}
      end)

    assert log =~ "Ignoring invalid agent.project_max_concurrent_agents entry"
  end

  test "defaults tracker settings for prd_json" do
    content = """
    ---
    tracker:
      kind: prd_json
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.tracker.kind == "prd_json"
    assert config.tracker.path == "prd.json"
    assert config.tracker.active_states == ["open", "in_progress", "pending_merge", "merged"]
    assert config.tracker.terminal_states == ["done", "merged", "failed", "cancelled"]
  end

  test "supports local tracker alias defaults" do
    content = """
    ---
    tracker:
      kind: local
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.tracker.path == "prd.json"
    assert config.tracker.active_states == ["open", "in_progress", "pending_merge", "merged"]
    assert config.tracker.terminal_states == ["done", "merged", "failed", "cancelled"]
  end

  test "parses agent retries_enabled setting" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: pi
      retries_enabled: false
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.agent.retries_enabled == false
  end

  test "uses defaults for checks, runtime, and review" do
    content = """
    ---
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)

    assert config.checks.required == []
    assert config.checks.timeout_ms == 7_200_000
    assert config.checks.fail_fast == true
    assert config.checks.max_cycles == 1

    assert config.runtime.kind == :host
    assert config.runtime.processes == []
    assert config.runtime.env == %{}
    assert config.runtime.ports == %{}
    assert config.runtime.port_offset_mod == 1000
    assert config.runtime.start_timeout_ms == 120_000
    assert config.runtime.stop_timeout_ms == 60_000

    assert config.quality.max_cycles == 1

    assert config.review.enabled == false
    assert config.review.max_cycles == 1
    assert config.review.agent.kind == :pi

    assert config.testing.enabled == false
    assert config.testing.max_cycles == 1
    assert config.testing.timeout_ms == 7_200_000
    assert config.testing.prompt_template == nil
    assert config.testing.agent.kind == :pi
    assert config.testing.agent.explicit == false

    assert config.preview.enabled == false
    assert config.preview.ttl_minutes == 120
    assert config.preview.reuse_testing_runtime == true
    assert config.preview.allow_on_demand_from_pending_merge == true
    assert config.preview.start_timeout_ms == 120_000
    assert config.preview.stop_timeout_ms == 60_000
  end

  test "parses checks and review settings" do
    content = """
    ---
    quality:
      max_cycles: 4
      checks:
        required:
          - mix format --check-formatted
          - mix test
        timeout_ms: 600000
        fail_fast: false
        max_cycles: 2
      review:
        enabled: true
        max_cycles: 3
        prompt_template: "Review {{ issue.identifier }}"
        agent:
          kind: claude
          command: /usr/local/bin/claude
          args:
            - --print
          env:
            REVIEW_MODE: strict
          timeout_ms: 120000
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)

    assert config.checks.required == ["mix format --check-formatted", "mix test"]
    assert config.checks.timeout_ms == 600_000
    assert config.checks.fail_fast == false
    assert config.checks.max_cycles == 2

    assert config.quality.max_cycles == 4

    assert config.review.enabled == true
    assert config.review.max_cycles == 3
    assert config.review.prompt_template == "Review {{ issue.identifier }}"
    assert config.review.agent.kind == :claude
    assert config.review.agent.command == "/usr/local/bin/claude"
    assert config.review.agent.args == ["--print"]
    assert config.review.agent.env == %{"REVIEW_MODE" => "strict"}
    assert config.review.agent.timeout_ms == 120_000
  end

  test "parses quality.testing and preview settings" do
    content = """
    ---
    quality:
      max_cycles: 4
      testing:
        enabled: true
        max_cycles: 3
        timeout_ms: 180000
        prompt_template: "Test {{ issue.identifier }}"
        agent:
          kind: cursor
          command: /usr/local/bin/cursor
          args:
            - --print
          env:
            TEST_MODE: smoke
          timeout_ms: 110000
    preview:
      enabled: true
      ttl_minutes: 45
      reuse_testing_runtime: false
      allow_on_demand_from_pending_merge: false
      start_timeout_ms: 50000
      stop_timeout_ms: 25000
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)

    assert config.testing.enabled == true
    assert config.testing.max_cycles == 3
    assert config.testing.timeout_ms == 180_000
    assert config.testing.prompt_template == "Test {{ issue.identifier }}"
    assert config.testing.agent.kind == :cursor
    assert config.testing.agent.command == "/usr/local/bin/cursor"
    assert config.testing.agent.args == ["--print"]
    assert config.testing.agent.env == %{"TEST_MODE" => "smoke"}
    assert config.testing.agent.timeout_ms == 110_000
    assert config.testing.agent.explicit == true

    assert config.preview.enabled == true
    assert config.preview.ttl_minutes == 45
    assert config.preview.reuse_testing_runtime == false
    assert config.preview.allow_on_demand_from_pending_merge == false
    assert config.preview.start_timeout_ms == 50_000
    assert config.preview.stop_timeout_ms == 25_000
  end

  test "rejects invalid quality.testing.enabled" do
    content = """
    ---
    quality:
      testing:
        enabled: maybe
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "quality.testing.enabled"
    assert msg =~ "boolean"
  end

  test "rejects non-map quality.testing.agent" do
    content = """
    ---
    quality:
      testing:
        agent: cursor
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "quality.testing.agent must be a map"
  end

  test "rejects invalid quality.testing.agent.kind" do
    content = """
    ---
    quality:
      testing:
        agent:
          kind: invalid
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "quality.testing.agent.kind"
  end

  test "rejects invalid preview.enabled" do
    content = """
    ---
    preview:
      enabled: sometimes
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "preview.enabled"
    assert msg =~ "boolean"
  end

  test "parses publish and git policy settings" do
    content = """
    ---
    publish:
      provider: gitlab
      auto_push: on_pass
      auto_merge: on_pass
      auto_create_pr: draft
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.publish.provider == :gitlab
    assert config.publish.mode == :auto_merge
    assert config.publish.auto_push == :on_pass
    assert config.publish.auto_merge == :on_pass
    assert config.publish.auto_create_pr == :draft
  end

  test "parses publish.mode auto_merge as alias for merge" do
    content = """
    ---
    publish:
      provider: github
      mode: auto_merge
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.publish.mode == :auto_merge
    assert Config.effective_publish_mode(config) == :merge
  end

  test "omitting publish.mode preserves provider defaults" do
    content = """
    ---
    publish:
      provider: github
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.publish.mode == nil
    assert Config.effective_publish_mode(config) == :pr
  end

  test "effective_publish_mode uses provider defaults when mode is not set" do
    github_config = %Config{publish: %{provider: :github, mode: nil}, project_provider: nil}
    gitlab_config = %Config{publish: %{provider: :gitlab, mode: nil}, project_provider: nil}
    local_config = %Config{publish: %{provider: nil, mode: nil}, project_provider: :local}
    unknown_config = %Config{publish: %{provider: nil, mode: nil}, project_provider: nil}

    assert Config.effective_publish_mode(github_config) == :pr
    assert Config.effective_publish_mode(gitlab_config) == :pr
    assert Config.effective_publish_mode(local_config) == :merge
    assert Config.effective_publish_mode(unknown_config) == :push
  end

  test "derives mode from legacy publish fields and logs deprecation warning" do
    content = """
    ---
    publish:
      auto_push: on_pass
      auto_create_pr: ready
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    log =
      capture_log(fn ->
        assert {:ok, config, _} = Config.parse(content)
        assert config.publish.mode == :pr
      end)

    assert log =~ "deprecated"
    assert log =~ "publish.mode"
  end

  test "derives auto_merge mode from legacy auto_merge on_pass without auto_push" do
    content = """
    ---
    publish:
      auto_merge: on_pass
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    log =
      capture_log(fn ->
        assert {:ok, config, _} = Config.parse(content)
        assert config.publish.mode == :auto_merge
      end)

    assert log =~ "deprecated"
  end

  test "parses ready PR policy" do
    content = """
    ---
    publish:
      provider: github
      auto_push: never
      auto_create_pr: ready
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.publish.provider == :github
    assert config.publish.auto_push == :never
    assert config.publish.auto_create_pr == :ready
  end

  test "rejects invalid publish.provider" do
    content = """
    ---
    publish:
      provider: bitbucket
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid publish.provider"
  end

  test "rejects invalid publish.auto_push" do
    content = """
    ---
    publish:
      auto_push: always
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid publish.auto_push"
  end

  test "rejects invalid publish.auto_merge" do
    content = """
    ---
    publish:
      auto_merge: always
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid publish.auto_merge"
  end

  test "rejects invalid publish.auto_create_pr" do
    content = """
    ---
    publish:
      auto_create_pr: yes
    workspace:
      root: /tmp
    agent:
      kind: amp
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid publish.auto_create_pr"
  end

  test "parses runtime settings" do
    content = """
    ---
    runtime:
      processes:
        - server
        - worker
      env:
        MIX_ENV: test
      ports:
        PORT: "4000"
        LIVEBOOK_PORT: 8080
      port_offset_mod: 250
      start_timeout_ms: 30000
      stop_timeout_ms: 15000
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(content)
    assert config.runtime.processes == ["server", "worker"]
    assert config.runtime.env == %{"MIX_ENV" => "test"}
    assert config.runtime.ports == %{"PORT" => 4000, "LIVEBOOK_PORT" => 8080}
    assert config.runtime.port_offset_mod == 250
    assert config.runtime.start_timeout_ms == 30_000
    assert config.runtime.stop_timeout_ms == 15_000
  end

  test "rejects invalid runtime kind" do
    content = """
    ---
    runtime:
      kind: invalid
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime.kind must be one of: host, docker"
  end

  test "rejects legacy runtime.profile key" do
    content = """
    ---
    runtime:
      profile: checks_only
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime.profile is no longer supported"
  end

  test "rejects legacy runtime.full_stack key" do
    content = """
    ---
    runtime:
      full_stack:
        command: pitchfork
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime.full_stack is no longer supported"
  end

  test "rejects invalid runtime port value" do
    content = """
    ---
    runtime:
      ports:
        PORT: not-a-number
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime.ports.PORT"
  end

  test "rejects non-map runtime section" do
    content = """
    ---
    runtime: pitchfork
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime must be a map"
  end

  test "rejects invalid review.agent.kind" do
    content = """
    ---
    quality:
      review:
        enabled: true
        agent:
          kind: invalid
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "Invalid agent.kind"
  end
end
