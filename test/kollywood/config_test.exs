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
    max_turns: 10
  ---

  You are working on {{ issue.identifier }}.
  """

  test "parses valid WORKFLOW.md content" do
    assert {:ok, config, template} = Config.parse(@valid_workflow)
    assert config.agent.kind == :amp
    assert config.agent.max_concurrent_agents == 3
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
    for kind <- ~w(amp claude opencode pi) do
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
    assert config.agent.max_concurrent_agents == 5
    assert config.agent.max_turns == 20
    assert config.agent.retries_enabled == true
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

    assert config.runtime.profile == :checks_only
    assert config.runtime.full_stack.command == "devenv"
    assert config.runtime.full_stack.processes == []
    assert config.runtime.full_stack.env == %{}
    assert config.runtime.full_stack.ports == %{}
    assert config.runtime.full_stack.port_offset_mod == 1000
    assert config.runtime.full_stack.start_timeout_ms == 120_000
    assert config.runtime.full_stack.stop_timeout_ms == 60_000

    assert config.review.enabled == false
    assert config.review.max_cycles == 1
    assert config.review.pass_token == "REVIEW_PASS"
    assert config.review.fail_token == "REVIEW_FAIL"
    assert config.review.agent.kind == :pi
  end

  test "parses checks and review settings" do
    content = """
    ---
    checks:
      required:
        - mix format --check-formatted
        - mix test
      timeout_ms: 600000
      fail_fast: false
    review:
      enabled: true
      max_cycles: 3
      pass_token: OK_TO_MERGE
      fail_token: NEEDS_WORK
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

    assert config.review.enabled == true
    assert config.review.max_cycles == 3
    assert config.review.pass_token == "OK_TO_MERGE"
    assert config.review.fail_token == "NEEDS_WORK"
    assert config.review.prompt_template == "Review {{ issue.identifier }}"
    assert config.review.agent.kind == :claude
    assert config.review.agent.command == "/usr/local/bin/claude"
    assert config.review.agent.args == ["--print"]
    assert config.review.agent.env == %{"REVIEW_MODE" => "strict"}
    assert config.review.agent.timeout_ms == 120_000
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

  test "parses publish.mode auto_merge explicitly" do
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
    assert Config.effective_publish_mode(config) == :auto_merge
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
    assert Config.effective_publish_mode(local_config) == :auto_merge
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

  test "parses full_stack runtime settings" do
    content = """
    ---
    runtime:
      profile: full_stack
      full_stack:
        command: /usr/local/bin/devenv
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
    assert config.runtime.profile == :full_stack
    assert config.runtime.full_stack.command == "/usr/local/bin/devenv"
    assert config.runtime.full_stack.processes == ["server", "worker"]
    assert config.runtime.full_stack.env == %{"MIX_ENV" => "test"}
    assert config.runtime.full_stack.ports == %{"PORT" => 4000, "LIVEBOOK_PORT" => 8080}
    assert config.runtime.full_stack.port_offset_mod == 250
    assert config.runtime.full_stack.start_timeout_ms == 30_000
    assert config.runtime.full_stack.stop_timeout_ms == 15_000
  end

  test "rejects invalid runtime profile" do
    content = """
    ---
    runtime:
      profile: invalid
    workspace:
      root: /tmp
    agent:
      kind: pi
    ---
    prompt
    """

    assert {:error, msg} = Config.parse(content)
    assert msg =~ "runtime.profile"
  end

  test "rejects invalid runtime.full_stack port value" do
    content = """
    ---
    runtime:
      profile: full_stack
      full_stack:
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
    assert msg =~ "runtime.full_stack.ports.PORT"
  end

  test "rejects non-map runtime section" do
    content = """
    ---
    runtime: full_stack
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
