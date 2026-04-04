defmodule Kollywood.PreviewSessionManagerTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.PreviewSessionManager
  alias Kollywood.Runtime
  alias Kollywood.RuntimeSessions

  setup do
    assert :ok = RuntimeSessions.clear()
    :ok
  end

  test "start_preview reuses persisted testing runtime session" do
    project_slug = "kollywood"
    story_id = "US-REUSE-#{System.unique_integer([:positive])}"
    workspace_path = Path.join(System.tmp_dir!(), "preview-reuse-#{story_id}")
    File.mkdir_p!(workspace_path)

    runtime_config = %{
      runtime: %{
        kind: :host,
        processes: [],
        ports: %{},
        env: %{"KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK" => "1"}
      }
    }

    runtime_state = Runtime.init(:host, runtime_config, %{path: workspace_path, key: story_id})

    persisted_state =
      runtime_state
      |> Map.put(:resolved_ports, %{"PORT" => 4555})
      |> Map.put(:env, Map.put(runtime_state.env, "KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK", "1"))

    assert :ok =
             RuntimeSessions.upsert(project_slug, story_id, persisted_state,
               session_type: :testing,
               status: :running,
               started_at: DateTime.utc_now()
             )

    assert {:ok, session} =
             PreviewSessionManager.start_preview(project_slug, story_id,
               config: runtime_config,
               workspace_path: workspace_path,
               workspace_key: story_id
             )

    assert session.status == :running
    assert session.resolved_ports == %{"PORT" => 4555}
    assert session.preview_url == "http://localhost:4555"

    assert :ok = PreviewSessionManager.stop_preview(project_slug, story_id)
    assert nil == RuntimeSessions.get(project_slug, story_id)
  end
end
