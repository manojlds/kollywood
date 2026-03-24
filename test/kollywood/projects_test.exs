defmodule Kollywood.ProjectsTest do
  use ExUnit.Case, async: false

  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.Repo

  setup do
    Repo.delete_all(Project)
    :ok
  end

  test "creates a local project with generated slug and default paths" do
    local_path = Path.join(System.tmp_dir!(), "kollywood_projects_test_local")

    assert {:ok, project} =
             Projects.create_project(%{
               name: "My Local App",
               provider: :local,
               local_path: local_path
             })

    assert project.slug == "my-local-app"
    assert project.provider == :local
    assert project.default_branch == "main"
    assert project.workflow_path == Path.join(Path.expand(local_path), "WORKFLOW.md")
    assert project.tracker_path == Path.join(Path.expand(local_path), "prd.json")
  end

  test "requires repository for github and gitlab providers" do
    assert {:error, changeset} =
             Projects.create_project(%{
               name: "Remote App",
               provider: :github,
               slug: "remote-app"
             })

    assert errors_on(changeset, :repository) != []
  end

  test "enforces unique project slug" do
    assert {:ok, _project} =
             Projects.create_project(%{
               name: "Project One",
               provider: :local,
               local_path: "/tmp/project-one",
               slug: "unique-slug"
             })

    assert {:error, changeset} =
             Projects.create_project(%{
               name: "Project Two",
               provider: :local,
               local_path: "/tmp/project-two",
               slug: "unique-slug"
             })

    assert errors_on(changeset, :slug) != []
  end

  defp errors_on(changeset, field) do
    changeset.errors
    |> Enum.filter(fn {error_field, _details} -> error_field == field end)
  end
end
