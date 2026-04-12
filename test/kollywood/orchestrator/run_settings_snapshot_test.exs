defmodule Kollywood.Orchestrator.RunSettingsSnapshotTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunSettingsSnapshot

  test "runtime image is nil when omitted" do
    workflow = """
    ---
    schema_version: 1
    workspace:
      root: /tmp
    agent:
      kind: pi
    runtime:
      kind: docker
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(workflow)

    snapshot = RunSettingsSnapshot.build(config)

    assert get_in(snapshot, ["workflow", "version"]) == "1"
    assert get_in(snapshot, ["resolved", "runtime", "image"]) == "nil"
    assert get_in(snapshot, ["sources", "runtime", "image"]) == "default"
  end

  test "runtime image is included when configured" do
    workflow = """
    ---
    schema_version: 1
    workspace:
      root: /tmp
    agent:
      kind: pi
    runtime:
      kind: docker
      image: ghcr.io/acme/runtime:2.0.0
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(workflow)

    snapshot = RunSettingsSnapshot.build(config)

    assert get_in(snapshot, ["workflow", "version"]) == "1"
    assert get_in(snapshot, ["resolved", "runtime", "image"]) == "ghcr.io/acme/runtime:2.0.0"
    assert get_in(snapshot, ["sources", "runtime", "image"]) == "workflow"
  end

  test "agent completion and idle timeout sources are captured" do
    workflow = """
    ---
    schema_version: 1
    workspace:
      root: /tmp
    agent:
      kind: pi
      completion_signals:
        - TASK_DONE
      idle_timeout_ms: 12000
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(workflow)

    snapshot = RunSettingsSnapshot.build(config)

    assert get_in(snapshot, ["workflow", "version"]) == "1"
    assert get_in(snapshot, ["resolved", "agent", "completion_signals"]) == ["TASK_DONE"]
    assert get_in(snapshot, ["resolved", "agent", "idle_timeout_ms"]) == 12_000
    assert get_in(snapshot, ["sources", "agent", "completion_signals"]) == "workflow"
    assert get_in(snapshot, ["sources", "agent", "idle_timeout_ms"]) == "workflow"
  end

  test "resolved phase agent keeps explicit role with harness defaults" do
    workflow = """
    ---
    schema_version: 1
    workspace:
      root: /tmp
    agent:
      kind: opencode
      command: /usr/local/bin/opencode
      args:
        - --json
      env:
        BASE_ENV: base
      timeout_ms: 90000
    quality:
      review:
        enabled: true
        max_cycles: 2
        agent:
          explicit: true
          kind: codex
      testing:
        enabled: true
        max_cycles: 2
        timeout_ms: 120000
        agent:
          explicit: true
          kind: cursor
    ---
    prompt
    """

    assert {:ok, config, _} = Config.parse(workflow)

    snapshot = RunSettingsSnapshot.build(config)

    assert get_in(snapshot, ["workflow", "version"]) == "1"
    assert get_in(snapshot, ["resolved", "review", "agent", "kind"]) == "codex"

    assert get_in(snapshot, ["resolved", "review", "agent", "command"]) ==
             "/usr/local/bin/opencode"

    assert get_in(snapshot, ["resolved", "review", "agent", "args"]) == ["--json"]
    assert get_in(snapshot, ["resolved", "review", "agent", "env", "BASE_ENV"]) == "base"

    assert get_in(snapshot, ["resolved", "testing", "agent", "kind"]) == "cursor"

    assert get_in(snapshot, ["resolved", "testing", "agent", "command"]) ==
             "/usr/local/bin/opencode"

    assert get_in(snapshot, ["resolved", "testing", "agent", "timeout_ms"]) == 7_200_000
  end

  test "workflow_identity_from_file records schema version when parse succeeds" do
    workflow = """
    ---
    schema_version: 1
    workspace:
      root: /tmp
    agent:
      kind: opencode
    ---
    prompt
    """

    identity = RunSettingsSnapshot.workflow_identity_from_file("/tmp/WORKFLOW.md", workflow)

    assert identity["identity_source"] == "workflow_file"
    assert identity["version"] == "1"
  end
end
