defmodule Kollywood.ProjectsTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Projects

  test "creates a local project with generated slug and managed paths" do
    assert {:ok, project} =
             Projects.create_project(%{
               name: "My Local App",
               provider: :local,
               repository: "/home/user/projects/my-local-app",
               max_concurrent_agents: 2
             })

    managed_root = Kollywood.ServiceConfig.project_repos_path("my-local-app")

    assert project.slug == "my-local-app"
    assert project.provider == :local
    assert project.default_branch == "main"

    assert Projects.local_path(project) == Path.expand(managed_root)

    assert Projects.workflow_path(project) ==
             Path.join(["/home/user/projects/my-local-app", ".kollywood", "WORKFLOW.md"])

    assert project.tracker_path == Kollywood.ServiceConfig.project_tracker_path("my-local-app")
    assert project.max_concurrent_agents == 2
  end

  test "rejects non-positive max_concurrent_agents" do
    assert {:error, changeset} =
             Projects.create_project(%{
               name: "My Local App",
               provider: :local,
               repository: "/home/user/projects/my-local-app",
               max_concurrent_agents: 0
             })

    assert errors_on(changeset, :max_concurrent_agents) != []
  end

  test "requires repository for all providers" do
    for provider <- [:local, :github, :gitlab] do
      assert {:error, changeset} =
               Projects.create_project(%{
                 name: "App",
                 provider: provider
               })

      assert errors_on(changeset, :repository) != [],
             "expected :repository error for provider #{provider}"
    end
  end

  test "enforces unique project slug" do
    assert {:ok, _project} =
             Projects.create_project(%{
               name: "Project One",
               provider: :local,
               repository: "/tmp/project-one",
               slug: "unique-slug"
             })

    assert {:error, changeset} =
             Projects.create_project(%{
               name: "Project Two",
               provider: :local,
               repository: "/tmp/project-two",
               slug: "unique-slug"
             })

    assert errors_on(changeset, :slug) != []
  end

  defp errors_on(changeset, field),
    do: Enum.filter(changeset.errors, fn {k, _} -> k == field end)
end
