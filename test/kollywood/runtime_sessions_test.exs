defmodule Kollywood.RuntimeSessionsTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Runtime
  alias Kollywood.RuntimeSessions

  setup do
    assert :ok = RuntimeSessions.clear()
    :ok
  end

  test "upsert/get persists runtime state and metadata" do
    workspace_path =
      Path.join(System.tmp_dir!(), "rt-sessions-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)

    runtime_state = Runtime.init(:host, %{runtime: %{}}, %{path: workspace_path, key: "US-RT-1"})
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 3_600, :second)

    assert :ok =
             RuntimeSessions.upsert("kollywood", "US-RT-1", runtime_state,
               status: :running,
               session_type: :testing,
               started_at: now,
               expires_at: expires_at,
               last_error: nil
             )

    assert {:ok, session} = RuntimeSessions.get("kollywood", "US-RT-1")
    assert session.project_slug == "kollywood"
    assert session.story_id == "US-RT-1"
    assert session.status == :running
    assert session.session_type == :testing
    assert session.runtime_kind == :host
    assert session.workspace_path == workspace_path
    assert session.runtime_state.workspace_path == workspace_path
    assert session.expires_at == expires_at
  end

  test "list supports status/session_type filters" do
    now = DateTime.utc_now()

    workspace_a =
      Path.join(System.tmp_dir!(), "rt-sessions-a-#{System.unique_integer([:positive])}")

    workspace_b =
      Path.join(System.tmp_dir!(), "rt-sessions-b-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_a)
    File.mkdir_p!(workspace_b)

    runtime_a = Runtime.init(:host, %{runtime: %{}}, %{path: workspace_a, key: "US-1"})
    runtime_b = Runtime.init(:host, %{runtime: %{}}, %{path: workspace_b, key: "US-2"})

    assert :ok =
             RuntimeSessions.upsert("kollywood", "US-1", runtime_a,
               status: :running,
               session_type: :testing
             )

    assert :ok =
             RuntimeSessions.upsert("kollywood", "US-2", runtime_b,
               status: :failed,
               session_type: :preview,
               last_error: "boot timeout",
               started_at: now
             )

    assert {:ok, running} = RuntimeSessions.list(status: :running)
    assert Enum.map(running, & &1.story_id) == ["US-1"]

    assert {:ok, preview} = RuntimeSessions.list(session_type: :preview)
    assert Enum.map(preview, & &1.story_id) == ["US-2"]
  end
end
