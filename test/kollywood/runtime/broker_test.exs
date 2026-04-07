defmodule Kollywood.Runtime.BrokerTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Runtime
  alias Kollywood.Runtime.Broker
  alias Kollywood.RuntimeSessions

  setup do
    assert :ok = RuntimeSessions.clear()
    :ok
  end

  test "context normalizes defaults and runtime metadata" do
    runtime = %{kind: "docker", profile: :checks_only}

    context =
      Broker.context("  proj  ", "  STORY-1  ", runtime,
        session_type: "preview",
        metadata: %{source: "test"}
      )

    assert context.project_slug == "proj"
    assert context.story_id == "STORY-1"
    assert context.session_type == :preview
    assert context.runtime_profile == :checks_only
    assert context.runtime_kind == :docker
    assert context.metadata == %{source: "test"}
  end

  test "persist_runtime_session upserts and clear_runtime_session deletes entry" do
    workspace_path =
      Path.join(System.tmp_dir!(), "runtime-broker-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)

    runtime =
      Runtime.init(:host, %{runtime: %{}}, %{path: workspace_path, key: "US-BROKER-1"})
      |> Map.put(:started?, true)
      |> Map.put(:process_state, :running)

    context = Broker.context("kollywood", "US-BROKER-1", runtime)

    assert :ok =
             Broker.persist_runtime_session(runtime, context,
               status: :running,
               session_type: :testing,
               started_at: DateTime.utc_now()
             )

    assert {:ok, persisted} = RuntimeSessions.get("kollywood", "US-BROKER-1")
    assert persisted.status == :running
    assert persisted.session_type == :testing
    assert persisted.story_id == "US-BROKER-1"

    assert :ok = Broker.clear_runtime_session(context)
    assert nil == RuntimeSessions.get("kollywood", "US-BROKER-1")
  end

  test "persist_runtime_session is a no-op when context has no story id" do
    runtime = Runtime.default_state(:host, %{runtime: %{}})
    context = Broker.context("kollywood", "", runtime)

    assert :ok = Broker.persist_runtime_session(runtime, context)
    assert {:ok, []} = RuntimeSessions.list()
  end
end
