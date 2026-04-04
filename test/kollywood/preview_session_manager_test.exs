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

    assert {:ok, _session} =
             PreviewSessionManager.start_preview(project_slug, story_id,
               config: runtime_config,
               workspace_path: workspace_path,
               workspace_key: story_id
             )

    session = await_session_status(project_slug, story_id, :running)
    assert session.resolved_ports == %{"PORT" => 4555}
    assert session.preview_url == "http://localhost:4555"

    assert :ok = PreviewSessionManager.stop_preview(project_slug, story_id)
    assert nil == RuntimeSessions.get(project_slug, story_id)
  end

  defp await_session_status(project_slug, story_id, expected_status, attempts_left \\ 30)

  defp await_session_status(_project_slug, _story_id, _expected_status, attempts_left)
       when attempts_left <= 0 do
    flunk("preview session did not reach expected status")
  end

  defp await_session_status(project_slug, story_id, expected_status, attempts_left) do
    case PreviewSessionManager.get_session(project_slug, story_id) do
      %{status: ^expected_status} = session ->
        session

      _other ->
        Process.sleep(25)
        await_session_status(project_slug, story_id, expected_status, attempts_left - 1)
    end
  end
end
