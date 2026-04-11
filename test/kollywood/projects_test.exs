defmodule Kollywood.ProjectsTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Projects

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_projects_test_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")

    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "creates a local project with generated slug and managed paths" do
    assert {:ok, project} =
             Projects.create_project(%{
               name: "My Local App",
               provider: :local,
               repository: "/home/user/projects/my-local-app"
             })

    managed_root = Kollywood.ServiceConfig.project_repos_path("my-local-app")

    assert project.slug == "my-local-app"
    assert project.provider == :local
    assert project.default_branch == "main"

    assert Projects.local_path(project) == Path.expand(managed_root)

    assert Projects.workflow_path(project) ==
             Path.join(["/home/user/projects/my-local-app", ".kollywood", "WORKFLOW.md"])

    assert Projects.tracker_path(project) ==
             Kollywood.ServiceConfig.project_tracker_path("my-local-app")

    tracker_path = Projects.tracker_path(project)
    assert File.exists?(tracker_path)

    {:ok, decoded} = tracker_path |> File.read!() |> Jason.decode()
    assert decoded["userStories"] == []
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

  test "onboarded? requires workflow file" do
    assert {:ok, project} =
             Projects.create_project(%{
               name: "Onboard check",
               provider: :local,
               repository:
                 Path.join(
                   System.tmp_dir!(),
                   "onboard-check-#{System.unique_integer([:positive])}"
                 )
             })

    refute Projects.onboarded?(project)

    tracker_path = Projects.tracker_path(project)
    File.mkdir_p!(Path.dirname(tracker_path))
    File.write!(tracker_path, ~s({"project":"demo","userStories":[]}))

    refute Projects.onboarded?(project)

    workflow_path = Projects.workflow_path(project)
    File.mkdir_p!(Path.dirname(workflow_path))

    File.write!(
      workflow_path,
      "---\nagent:\n  kind: opencode\nworkspace:\n  strategy: clone\n---\n"
    )

    assert Projects.onboarded?(project)
  end

  defp errors_on(changeset, field),
    do: Enum.filter(changeset.errors, fn {k, _} -> k == field end)
end
