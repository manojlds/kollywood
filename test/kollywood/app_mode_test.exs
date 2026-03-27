defmodule Kollywood.AppModeTest do
  use ExUnit.Case, async: true

  alias Kollywood.AppMode

  test "normalize returns supported modes" do
    assert AppMode.normalize(:all) == :all
    assert AppMode.normalize(:web) == :web
    assert AppMode.normalize(:orchestrator) == :orchestrator
    assert AppMode.normalize(:worker) == :worker

    assert AppMode.normalize("web") == :web
    assert AppMode.normalize("orchestrator") == :orchestrator
    assert AppMode.normalize("worker") == :worker
    assert AppMode.normalize("  all  ") == :all
  end

  test "normalize defaults unknown values to all" do
    assert AppMode.normalize(nil) == :all
    assert AppMode.normalize(:unknown) == :all
    assert AppMode.normalize("unknown") == :all
  end

  test "capability helpers match mode" do
    assert AppMode.web_enabled?(:all)
    assert AppMode.web_enabled?(:web)
    refute AppMode.web_enabled?(:orchestrator)
    refute AppMode.web_enabled?(:worker)

    assert AppMode.data_enabled?(:all)
    assert AppMode.data_enabled?(:web)
    assert AppMode.data_enabled?(:orchestrator)
    refute AppMode.data_enabled?(:worker)

    assert AppMode.orchestrator_enabled?(:all)
    assert AppMode.orchestrator_enabled?(:orchestrator)
    refute AppMode.orchestrator_enabled?(:web)
    refute AppMode.orchestrator_enabled?(:worker)

    assert AppMode.agent_pool_enabled?(:all)
    assert AppMode.agent_pool_enabled?(:orchestrator)
    assert AppMode.agent_pool_enabled?(:worker)
    refute AppMode.agent_pool_enabled?(:web)
  end
end
