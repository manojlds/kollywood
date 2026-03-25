defmodule KollywoodWeb.DashboardLiveTest do
  use KollywoodWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kollywood.Projects
  alias Kollywood.Repo

  setup do
    Repo.delete_all(Kollywood.Projects.Project)

    {:ok, project} =
      Projects.create_project(%{
        name: "Test Project",
        provider: :local,
        local_path: "/tmp/test_dashboard_project"
      })

    %{project: project}
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

      view |> element("a", "Stories") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/stories")

      view |> element("a", "Runs") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/runs")

      view |> element("a", "Settings") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/settings")
    end

    test "shows not found for nonexistent project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects/nonexistent")

      assert html =~ "Project not found"
    end
  end
end
