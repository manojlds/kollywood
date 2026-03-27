defmodule KollywoodWeb.StoryControllerTest do
  use KollywoodWeb.ConnCase, async: true

  alias Kollywood.Projects

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_story_controller_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    tracker_path = Path.join(root, "prd.json")

    write_prd!(tracker_path, [
      %{
        "id" => "US-001",
        "title" => "Draft story",
        "status" => "draft",
        "priority" => 1,
        "dependsOn" => []
      },
      %{
        "id" => "US-002",
        "title" => "Open story",
        "status" => "open",
        "priority" => 2,
        "dependsOn" => ["US-001"]
      }
    ])

    {:ok, project} =
      Projects.create_project(%{
        name: "Story API #{System.unique_integer([:positive])}",
        slug: "story-api-#{System.unique_integer([:positive])}",
        provider: :local,
        repository: root,
        local_path: root,
        tracker_path: tracker_path
      })

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{project: project, tracker_path: tracker_path}
  end

  test "index returns local tracker stories", %{conn: conn, project: project} do
    conn = get(conn, ~p"/api/projects/#{project.slug}/stories")

    assert %{"data" => stories} = json_response(conn, 200)
    assert Enum.any?(stories, &(&1["id"] == "US-001"))

    draft_story = Enum.find(stories, &(&1["id"] == "US-001"))
    assert draft_story["allowed_status_transitions"] == ["open", "cancelled"]
  end

  test "create adds a story", %{conn: conn, project: project, tracker_path: tracker_path} do
    payload = %{
      "story" => %{
        "title" => "New API Story",
        "status" => "draft",
        "priority" => 3,
        "dependsOn" => "US-001",
        "acceptanceCriteria" => "first criterion\nsecond criterion"
      }
    }

    conn = post(conn, ~p"/api/projects/#{project.slug}/stories", payload)

    assert %{"data" => story} = json_response(conn, 201)
    assert story["title"] == "New API Story"
    assert story["status"] == "draft"

    story_ids = tracker_story_ids(tracker_path)
    assert Enum.any?(story_ids, &(&1 == story["id"]))
  end

  test "update rejects manual transition to in_progress", %{conn: conn, project: project} do
    payload = %{"story" => %{"status" => "in_progress"}}

    conn = patch(conn, ~p"/api/projects/#{project.slug}/stories/US-001", payload)

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "managed by the orchestrator"
  end

  test "delete blocks stories referenced by dependencies", %{conn: conn, project: project} do
    conn = delete(conn, ~p"/api/projects/#{project.slug}/stories/US-001")

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "depended on by US-002"
  end

  defp write_prd!(path, stories) do
    payload = %{
      "project" => "kollywood",
      "branchName" => "main",
      "description" => "story API fixture",
      "userStories" => stories
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp tracker_story_ids(path) do
    {:ok, content} = File.read(path)
    {:ok, decoded} = Jason.decode(content)

    decoded
    |> Map.fetch!("userStories")
    |> Enum.map(& &1["id"])
  end
end
