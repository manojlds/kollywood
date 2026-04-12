defmodule Kollywood.WorkflowStoreProjectContextTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.WorkflowStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_workflow_store_project_context_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    repo_root = Path.join(root, "repo")
    workflow_path = Path.join([repo_root, ".kollywood", "WORKFLOW.md"])
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_content())

    Repo.delete_all(Project)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)
    end)

    %{repo_root: repo_root, workflow_path: workflow_path}
  end

  test "refreshes workflow project context when projects are added and removed", %{
    repo_root: repo_root,
    workflow_path: workflow_path
  } do
    store_name = String.to_atom("workflow_store_ctx_#{System.unique_integer([:positive])}")
    store = start_supervised!({WorkflowStore, path: workflow_path, name: store_name})

    assert project_slug(store) == nil

    {:ok, project} =
      Projects.create_project(%{
        name: "Context Project",
        slug: "context-project",
        provider: :local,
        repository: repo_root
      })

    assert wait_until(fn -> project_slug(store) == project.slug end)

    assert {:ok, _deleted} = Projects.delete_project(project)
    assert wait_until(fn -> project_slug(store) == nil end)
  end

  defp project_slug(store) do
    case WorkflowStore.get_config(store) do
      nil -> nil
      config -> config.tracker |> Map.get(:project_slug)
    end
  end

  defp wait_until(fun, timeout_ms \\ 5_000) when is_function(fun, 0) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_until(fun, deadline_ms, timeout_ms)
  end

  defp wait_until(fun, deadline_ms, interval_ms) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        false
      else
        Process.sleep(min(interval_ms, 50))
        wait_until(fun, deadline_ms, interval_ms)
      end
    end
  end

  defp workflow_content do
    """
    ---
    schema_version: 1
    tracker:
      kind: prd_json
    workspace:
      strategy: clone
    agent:
      kind: opencode
    ---
    Hello {{ issue.identifier }}
    """
  end
end
