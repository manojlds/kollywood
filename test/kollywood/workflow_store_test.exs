defmodule Kollywood.WorkflowStoreTest do
  use ExUnit.Case, async: true

  alias Kollywood.WorkflowStore

  @valid_content """
  ---
  workspace:
    root: /tmp/test
  agent:
    kind: amp
  ---
  Hello {{ issue.identifier }}
  """

  setup do
    dir = System.tmp_dir!()
    path = Path.join(dir, "test_workflow_#{System.unique_integer([:positive])}.md")
    File.write!(path, @valid_content)
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "loads config on start", %{path: path} do
    pid =
      start_supervised!({WorkflowStore, path: path, name: :"store_#{System.unique_integer()}"})

    config = WorkflowStore.get_config(pid)
    assert config.agent.kind == :amp
    assert config.workspace.root == "/tmp/test"

    template = WorkflowStore.get_prompt_template(pid)
    assert template =~ "{{ issue.identifier }}"

    assert WorkflowStore.get_last_error(pid) == nil
  end

  test "detects file changes", %{path: path} do
    pid =
      start_supervised!({WorkflowStore, path: path, name: :"store_#{System.unique_integer()}"})

    assert WorkflowStore.get_config(pid).agent.kind == :amp

    updated = """
    ---
    workspace:
      root: /tmp/updated
    agent:
      kind: claude
    ---
    Updated prompt
    """

    # Write new content and wait for poll
    File.write!(path, updated)
    Process.sleep(1_500)

    assert WorkflowStore.get_config(pid).agent.kind == :claude
    assert WorkflowStore.get_config(pid).workspace.root == "/tmp/updated"
    assert WorkflowStore.get_prompt_template(pid) =~ "Updated prompt"
  end

  test "keeps last good config on bad reload", %{path: path} do
    pid =
      start_supervised!({WorkflowStore, path: path, name: :"store_#{System.unique_integer()}"})

    assert WorkflowStore.get_config(pid).agent.kind == :amp

    # Write invalid content
    File.write!(path, "this is not valid workflow markdown")
    Process.sleep(1_500)

    # Config should remain unchanged
    assert WorkflowStore.get_config(pid).agent.kind == :amp
    assert WorkflowStore.get_last_error(pid) != nil
  end

  test "handles missing file on start" do
    pid =
      start_supervised!(
        {WorkflowStore,
         path: "/tmp/nonexistent_#{System.unique_integer()}.md",
         name: :"store_#{System.unique_integer()}"}
      )

    assert WorkflowStore.get_config(pid) == nil
    assert WorkflowStore.get_last_error(pid) != nil
  end
end
