defmodule Kollywood.Orchestrator.RunSettingsSnapshotTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunSettingsSnapshot

  test "runtime image is nil when omitted" do
    workflow = """
    ---
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

    assert get_in(snapshot, ["resolved", "runtime", "image"]) == "nil"
    assert get_in(snapshot, ["sources", "runtime", "image"]) == "default"
  end

  test "runtime image is included when configured" do
    workflow = """
    ---
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

    assert get_in(snapshot, ["resolved", "runtime", "image"]) == "ghcr.io/acme/runtime:2.0.0"
    assert get_in(snapshot, ["sources", "runtime", "image"]) == "workflow"
  end

  test "agent completion and idle timeout sources are captured" do
    workflow = """
    ---
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

    assert get_in(snapshot, ["resolved", "agent", "completion_signals"]) == ["TASK_DONE"]
    assert get_in(snapshot, ["resolved", "agent", "idle_timeout_ms"]) == 12_000
    assert get_in(snapshot, ["sources", "agent", "completion_signals"]) == "workflow"
    assert get_in(snapshot, ["sources", "agent", "idle_timeout_ms"]) == "workflow"
  end
end
