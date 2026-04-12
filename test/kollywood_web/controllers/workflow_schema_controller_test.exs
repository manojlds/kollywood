defmodule KollywoodWeb.WorkflowSchemaControllerTest do
  use KollywoodWeb.ConnCase, async: true

  test "returns versioned workflow schema payload", %{conn: conn} do
    conn = get(conn, ~p"/api/workflow/schema")

    assert %{"data" => data} = json_response(conn, 200)
    assert is_binary(data["schema_version"])

    assert %{"required_sections" => required_sections} = data["workflow_front_matter"]
    assert Enum.sort(required_sections) == Enum.sort(["agent", "workspace"])

    assert %{"sections" => sections} = data
    assert is_map(sections)

    assert %{"fields" => agent_fields} = sections["agent"]

    assert agent_fields["kind"]["allowed"] == [
             "claude",
             "codex",
             "cursor",
             "opencode",
             "pi"
           ]

    assert agent_fields["model"]["type"] == ["agent_model", "null"]
    assert agent_fields["model"]["description"] =~ "model identifier"

    assert sections["quality"]["fields"]["review"]["fields"]["agent"]["fields"]["model"]["type"] ==
             ["agent_model", "null"]

    assert sections["quality"]["fields"]["testing"]["fields"]["agent"]["fields"]["model"]["type"] ==
             ["agent_model", "null"]

    assert %{"fields" => workspace_fields} = sections["workspace"]
    assert workspace_fields["strategy"]["allowed"] == ["clone", "worktree"]
  end
end
