defmodule KollywoodWeb.DashboardLiveTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Projects
  alias Kollywood.Repo

  @test_stories [
    %{
      "id" => "US-001",
      "title" => "First Story",
      "status" => "open",
      "description" => "Description of first story",
      "acceptanceCriteria" => ["Must do X", "Must do Y"],
      "notes" => "Some notes here",
      "dependsOn" => [],
      "priority" => "high"
    },
    %{
      "id" => "US-002",
      "title" => "Second Story",
      "status" => "in_progress",
      "lastAttempt" => "20240101_120000",
      "lastError" => "Something went wrong"
    }
  ]

  setup do
    Repo.delete_all(Kollywood.Projects.Project)

    tmp_dir =
      Path.join(System.tmp_dir!(), "kollywood_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "prd.json"),
      Jason.encode!(%{"userStories" => @test_stories}, pretty: true)
    )

    {:ok, project} =
      Projects.create_project(%{
        name: "Dashboard Test Project #{System.unique_integer([:positive])}",
        provider: :local,
        local_path: tmp_dir
      })

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{project: project, tmp_dir: tmp_dir}
  end

  describe "projects index" do
    test "renders project list", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Projects"
      assert html =~ project.name
    end
  end

  describe "dashboard overview" do
    test "renders counters and navigation", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ project.name
      assert html =~ "Overview"
      assert html =~ "Stories"
      assert html =~ "Runs"
      assert html =~ "Settings"
      assert html =~ "Open"
      assert html =~ "In Progress"
      assert html =~ "Done"
      assert html =~ "Failed"
    end

    test "navigates between tabs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      view |> element("nav a", "Stories") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/stories")

      view |> element("nav a", "Runs") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/runs")

      view |> element("nav a", "Settings") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/settings")
    end

    test "shows not found for nonexistent project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects/nonexistent")

      assert html =~ "Project not found"
    end
  end

  describe "dashboard routes" do
    test "renders overview page", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      assert response =~ project.name
    end

    test "renders settings page", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/settings")
      response = html_response(conn, 200)

      assert response =~ "Project Settings"
    end
  end

  describe "overview section" do
    test "shows recent activity for stories with lastAttempt", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "Recent Activity"
      assert html =~ "US-002"
      assert html =~ "Second Story"
    end

    test "recent activity rows link to run detail", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "/projects/#{project.slug}/runs/US-002/20240101_120000"
    end
  end

  describe "settings section" do
    test "shows workflow_path and tracker_path labels", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/settings")
      response = html_response(conn, 200)

      assert response =~ "Workflow Path"
      assert response =~ "Tracker Path"
    end
  end

  describe "stories section" do
    test "lists stories from tracker file", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "US-001"
      assert html =~ "First Story"
      assert html =~ "US-002"
      assert html =~ "Second Story"
    end

    test "shows status change dropdown for each story", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "update_story_status"
    end
  end

  describe "show_story event" do
    test "opens story detail slide-over with story data", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      html =
        view
        |> element("button[phx-click='show_story'][phx-value-id='US-001']", "US-001")
        |> render_click()

      assert html =~ "First Story"
      assert html =~ "Description of first story"
      assert html =~ "Must do X"
      assert html =~ "Must do Y"
      assert html =~ "Some notes here"
      assert html =~ "high"
    end

    test "closes story detail on close event", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='show_story'][phx-value-id='US-001']", "US-001")
      |> render_click()

      html =
        view
        |> element("#close-story-btn")
        |> render_click()

      refute html =~ "Description of first story"
    end
  end

  describe "update_story_status event" do
    test "updates story status in tracker file on disk", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element(
        "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
      )
      |> render_click()

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))
      assert story["status"] == "done"
    end

    test "reflects updated status in the UI", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      html =
        view
        |> element(
          "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
        )
        |> render_click()

      assert html =~ "done"
    end
  end

  describe "run detail section" do
    test "run detail route renders with story info", %{conn: conn, project: project} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/US-002/20240101_120000")

      assert html =~ "Run Detail"
      assert html =~ "US-002"
      assert html =~ "Back to Runs"
    end

    test "shows no logs available when log files are missing", %{conn: conn, project: project} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/US-002/20240101_120000")

      assert html =~ "No logs available"
    end

    test "runs list shows view link for stories with lastAttempt", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "View"
      assert html =~ "/projects/#{project.slug}/runs/US-002/20240101_120000"
    end
  end
end
