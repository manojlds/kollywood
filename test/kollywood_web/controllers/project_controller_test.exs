defmodule KollywoodWeb.ProjectControllerTest do
  use KollywoodWeb.ConnCase, async: true

  alias Kollywood.Projects

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_project_controller_test_#{System.unique_integer([:positive])}"
      )

    one_path = Path.join(root, "one")
    nested_path = Path.join(one_path, "nested")
    other_path = Path.join(root, "other")

    File.mkdir_p!(nested_path)
    File.mkdir_p!(other_path)

    {:ok, one} =
      Projects.create_project(%{
        name: "One",
        slug: "one-#{System.unique_integer([:positive])}",
        provider: :local,
        repository: one_path
      })

    {:ok, nested} =
      Projects.create_project(%{
        name: "Nested",
        slug: "nested-#{System.unique_integer([:positive])}",
        provider: :local,
        repository: nested_path
      })

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root, one: one, nested: nested}
  end

  test "resolve picks the closest project path match", %{conn: conn, nested: nested, root: root} do
    target_path = Path.join([root, "one", "nested", "packages", "foo"])
    File.mkdir_p!(target_path)

    conn = get(conn, ~p"/api/projects/resolve", %{path: target_path})

    assert %{"data" => data} = json_response(conn, 200)
    assert data["slug"] == nested.slug
  end

  test "resolve returns not found when no project matches path", %{conn: conn, root: root} do
    unmatched_path = Path.join(root, "unmatched")
    File.mkdir_p!(unmatched_path)

    conn = get(conn, ~p"/api/projects/resolve", %{path: unmatched_path})

    assert %{"error" => error} = json_response(conn, 404)
    assert error =~ "no project mapped"
  end

  test "resolve rejects blank path", %{conn: conn} do
    conn = get(conn, ~p"/api/projects/resolve", %{path: "   "})

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "path must be a non-empty string"
  end
end
