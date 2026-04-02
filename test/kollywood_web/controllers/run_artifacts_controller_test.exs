defmodule KollywoodWeb.RunArtifactsControllerTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.ServiceConfig

  setup do
    slug = "run-artifacts-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), "kollywood_run_artifacts_test_#{slug}")
    File.mkdir_p!(root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Run Artifacts #{slug}",
        slug: slug,
        provider: :local,
        repository: root
      })

    config = %Config{
      workspace: %{root: Path.join(System.tmp_dir!(), "kollywood_run_artifact_workspaces")},
      tracker: %{project_slug: project.slug}
    }

    story_id = "US-ARTIFACT"
    issue = %{id: story_id, identifier: story_id, title: "Artifact story"}

    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)
    File.mkdir_p!(context.files.testing_artifacts_dir)

    filename = "001_preview.png"
    artifact_path = Path.join(context.files.testing_artifacts_dir, filename)
    File.write!(artifact_path, "fake-image")
    RunLogs.complete_attempt(context, %{status: "ok"})

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(ServiceConfig.project_data_dir(project.slug))
    end)

    %{project: project, story_id: story_id, filename: filename}
  end

  test "serves stored testing artifact file", %{
    conn: conn,
    project: project,
    story_id: story_id,
    filename: filename
  } do
    conn = get(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1/artifacts/#{filename}")

    assert response(conn, 200) == "fake-image"
    assert List.first(get_resp_header(conn, "content-type")) =~ "image/png"
  end

  test "returns 404 when artifact is missing", %{conn: conn, project: project, story_id: story_id} do
    conn = get(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1/artifacts/missing.png")
    assert response(conn, 404)
  end
end
