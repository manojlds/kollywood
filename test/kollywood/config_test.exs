defmodule Kollywood.ConfigTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config

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
    assert config.agent.max_concurrent_agents == 5
    assert config.agent.max_turns == 20
    assert config.agent.max_retry_backoff_ms == 300_000
    assert config.agent.command == nil
    assert config.agent.args == []
    assert config.agent.env == %{}
    assert config.agent.timeout_ms == 300_000
    assert config.tracker.active_states == ["Todo", "In Progress"]
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
    assert config.tracker.path == ".ralphi/prd.json"
    assert config.tracker.active_states == ["open", "in_progress"]
    assert config.tracker.terminal_states == ["done"]
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
    assert config.tracker.path == ".ralphi/prd.json"
    assert config.tracker.active_states == ["open", "in_progress"]
    assert config.tracker.terminal_states == ["done"]
  end
end
