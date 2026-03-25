defmodule Mix.Tasks.Kollywood.ProjectsTest do
  use Kollywood.DataCase, async: false

  import ExUnit.CaptureIO

  setup do
    root = Path.join(System.tmp_dir!(), "kollywood_projects_task_test")
    File.mkdir_p!(root)

    %{root: root}
  end

  test "add-local creates a project and list prints it", %{root: root} do
    local_path = Path.join(root, "demo")
    File.mkdir_p!(local_path)

    add_output =
      run_task("kollywood.projects", [
        "add-local",
        "--name",
        "Demo Project",
        "--path",
        local_path
      ])

    assert add_output =~ "Added project demo-project"

    list_output = run_task("kollywood.projects", ["list"])
    assert list_output =~ "demo-project"
    assert list_output =~ "provider=local"
  end

  test "add-github requires repo" do
    assert_raise Mix.Error, ~r/--repo is required/, fn ->
      run_task("kollywood.projects", ["add-github", "--name", "Backend"])
    end
  end

  defp run_task(task_name, args) do
    Mix.Task.reenable(task_name)
    capture_io(fn -> Mix.Task.run(task_name, args) end)
  end
end
