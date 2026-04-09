defmodule KollywoodWeb.RunEventsControllerTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.ServiceConfig

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_run_events_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    slug = "run-events-api-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(%{
        name: "Run Events API #{System.unique_integer([:positive])}",
        slug: slug,
        provider: :local,
        repository: root
      })

    tracker_path = Projects.tracker_path(project)
    File.mkdir_p!(Path.dirname(tracker_path))
    write_prd!(tracker_path)

    :ok = seed_attempt!(slug, "US-001")

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(Path.dirname(tracker_path))
      File.rm_rf!(ServiceConfig.project_data_dir(slug))
    end)

    %{project: project}
  end

  test "index returns events with next cursor", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/runs/US-001/1/events")

    assert %{"data" => data} = json_response(conn, 200)
    assert data["story_id"] == "US-001"
    assert data["attempt"] == 1
    assert data["since"] == 0
    assert data["status"] == "running"
    assert is_list(data["events"])
    assert length(data["events"]) == 3
    assert data["next_cursor"] == 3
  end

  test "index supports incremental fetch via since", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/runs/US-001/1/events", %{since: "2"})

    assert %{"data" => data} = json_response(conn, 200)
    assert length(data["events"]) == 1
    assert List.first(data["events"])["type"] == "turn_succeeded"
    assert data["next_cursor"] == 3
  end

  test "index supports optional limit", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/runs/US-001/1/events", %{limit: "2"})

    assert %{"data" => data} = json_response(conn, 200)
    assert length(data["events"]) == 2
    assert data["next_cursor"] == 2
  end

  test "index validates since", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/runs/US-001/1/events", %{since: "-1"})

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "since"
    assert error =~ "non-negative"
  end

  test "index returns not found for unknown attempt", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/runs/US-001/99/events")

    assert %{"error" => error} = json_response(conn, 404)
    assert error =~ "attempt"
    assert error =~ "not found"
  end

  defp write_prd!(path) do
    payload = %{
      "project" => "kollywood",
      "branchName" => "main",
      "description" => "run events API fixture",
      "userStories" => [
        %{
          "id" => "US-001",
          "title" => "Story",
          "status" => "open",
          "priority" => 1,
          "dependsOn" => []
        }
      ]
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp seed_attempt!(project_slug, story_id) do
    config = %Config{
      workspace: %{
        root: Path.join(System.tmp_dir!(), "kollywood_run_events_controller_workspaces")
      },
      tracker: %{project_slug: project_slug}
    }

    issue = %{id: story_id, identifier: story_id, title: "Story #{story_id}"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    :ok = RunLogs.append_event(context, %{type: :run_started})
    :ok = RunLogs.append_event(context, %{type: :turn_started, turn: 1})
    :ok = RunLogs.append_event(context, %{type: :turn_succeeded, turn: 1, output: "ok"})
    :ok
  end
end
