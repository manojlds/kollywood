defmodule KollywoodWeb.DashboardLiveTest do
  @moduledoc """
  Integration tests for the DashboardLive routes.
  """
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Projects
  alias Kollywood.Repo

  setup do
    Repo.delete_all(Kollywood.Projects.Project)

    # Create a test project with unique name
    {:ok, project} =
      Projects.create_project(%{
        name: "Dashboard Test Project #{System.unique_integer([:positive])}",
        provider: :local,
        local_path: "/tmp/test_dashboard_project"
      })

    %{project: project}
  end

  describe "dashboard routes" do
    test "overview route renders successfully", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      assert response =~ project.name
      assert response =~ "Overview"
      assert response =~ "Stories"
      assert response =~ "Runs"
      assert response =~ "Settings"
    end

    test "stories route renders successfully", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/stories")
      response = html_response(conn, 200)

      assert response =~ project.name
      assert response =~ "Stories"
    end

    test "runs route renders successfully", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/runs")
      response = html_response(conn, 200)

      assert response =~ project.name
      assert response =~ "Runs"
    end

    test "settings route renders successfully", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/settings")
      response = html_response(conn, 200)

      assert response =~ project.name
      assert response =~ "Settings"
    end

    test "shows no project selected state when project not found", %{conn: conn} do
      conn = get(conn, ~p"/projects/nonexistent")
      response = html_response(conn, 200)

      assert response =~ "Select a Project"
    end

    test "displays counter cards", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      assert response =~ "Open"
      assert response =~ "In Progress"
      assert response =~ "Done"
      assert response =~ "Failed"
    end

    test "displays project selector in header", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      # Should show project name when project is selected
      assert response =~ project.name
    end

    test "displays project information section", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      assert response =~ "Project Information"
    end
  end
end
