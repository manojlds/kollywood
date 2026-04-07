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

  test "persist_runtime_session force option upserts for non-running runtime" do
    workspace_path =
      Path.join(System.tmp_dir!(), "runtime-broker-force-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)

    runtime = Runtime.init(:host, %{runtime: %{}}, %{path: workspace_path, key: "US-BROKER-2"})
    context = Broker.context("kollywood", "US-BROKER-2", runtime, session_type: :preview)

    assert :ok =
             Broker.persist_runtime_session(runtime, context,
               force: true,
               status: :starting,
               session_type: :preview,
               preview_url: "http://localhost:4000",
               started_at: DateTime.utc_now(),
               expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
               last_error: "none"
             )

    assert {:ok, persisted} = RuntimeSessions.get("kollywood", "US-BROKER-2")
    assert persisted.status == :starting
    assert persisted.session_type == :preview
    assert persisted.preview_url == "http://localhost:4000"
  end

  test "get_runtime_session filters by session type" do
    workspace_path =
      Path.join(System.tmp_dir!(), "runtime-broker-get-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)

    runtime =
      Runtime.init(:host, %{runtime: %{}}, %{path: workspace_path, key: "US-BROKER-3"})
      |> Map.put(:started?, true)
      |> Map.put(:process_state, :running)

    context = Broker.context("kollywood", "US-BROKER-3", runtime, session_type: :testing)

    assert :ok = Broker.persist_runtime_session(runtime, context, session_type: :testing)

    assert {:ok, _session} = Broker.get_runtime_session(context, session_type: :testing)
    assert nil == Broker.get_runtime_session(context, session_type: :preview)
  end

  test "list_runtime_sessions proxies status/session_type filters" do
    workspace_a =
      Path.join(System.tmp_dir!(), "runtime-broker-list-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "runtime-broker-list-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)

    runtime_a =
      Runtime.init(:host, %{runtime: %{}}, %{path: workspace_a, key: "US-BROKER-4"})
      |> Map.put(:started?, true)
      |> Map.put(:process_state, :running)

    runtime_b = Runtime.init(:host, %{runtime: %{}}, %{path: workspace_b, key: "US-BROKER-5"})

    context_a = Broker.context("kollywood", "US-BROKER-4", runtime_a, session_type: :testing)
    context_b = Broker.context("kollywood", "US-BROKER-5", runtime_b, session_type: :preview)

    assert :ok = Broker.persist_runtime_session(runtime_a, context_a, status: :running)

    assert :ok =
             Broker.persist_runtime_session(runtime_b, context_b,
               force: true,
               status: :failed,
               session_type: :preview
             )

    assert {:ok, running} = Broker.list_runtime_sessions(status: :running)
    assert Enum.map(running, & &1.story_id) == ["US-BROKER-4"]

    assert {:ok, preview} = Broker.list_runtime_sessions(session_type: :preview)
    assert Enum.map(preview, & &1.story_id) == ["US-BROKER-5"]
  end
end
