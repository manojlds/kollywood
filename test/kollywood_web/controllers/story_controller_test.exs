defmodule KollywoodWeb.StoryControllerTest do
  use KollywoodWeb.ConnCase, async: true

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
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

  test "update stores story execution overrides", %{conn: conn, project: project} do
    payload = %{
      "story" => %{
        "settings" => %{
          "execution" => %{
            "agent_kind" => "cursor",
            "review_agent_kind" => "claude",
            "review_max_cycles" => "2"
          }
        }
      }
    }

    conn = patch(conn, ~p"/api/projects/#{project.slug}/stories/US-001", payload)

    assert %{"data" => story} = json_response(conn, 200)
    assert story["settings"]["execution"]["agent_kind"] == "cursor"
    assert story["settings"]["execution"]["review_agent_kind"] == "claude"
    assert story["settings"]["execution"]["review_max_cycles"] == 2
  end

  test "update rejects invalid execution override values", %{conn: conn, project: project} do
    payload = %{
      "story" => %{
        "settings" => %{
          "execution" => %{
            "review_max_cycles" => "zero"
          }
        }
      }
    }

    conn = patch(conn, ~p"/api/projects/#{project.slug}/stories/US-001", payload)

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "review_max_cycles"
  end

  test "delete blocks stories referenced by dependencies", %{conn: conn, project: project} do
    conn = delete(conn, ~p"/api/projects/#{project.slug}/stories/US-001")

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "depended on by US-002"
  end

  test "retry_step triggers a checks retry for a failed attempt", %{
    conn: conn,
    project: project
  } do
    write_workflow!(project, """
    ---
    tracker:
      kind: prd_json
    workspace:
      strategy: clone
    agent:
      kind: amp
      command: /bin/true
    quality:
      max_cycles: 1
      checks:
        required:
          - test -f ready.txt
        timeout_ms: 10000
        fail_fast: true
        max_cycles: 1
      review:
        enabled: false
        max_cycles: 1
    publish:
      mode: push
    orchestrator:
      retries_enabled: false
    git:
      base_branch: main
    ---

    Work on {{ issue.identifier }}.
    """)

    workspace_path =
      Path.join(System.tmp_dir!(), "story-controller-retry-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "ready.txt"), "ok\n")

    seed_failed_attempt!(project.slug, "US-001", workspace_path)

    conn =
      post(conn, ~p"/api/projects/#{project.slug}/stories/US-001/retries", %{
        "attempt" => "1",
        "step" => "checks"
      })

    assert %{"data" => data} = json_response(conn, 202)
    assert data["retry_step"] == "checks"
    assert data["parent_attempt"] == 1
    assert data["attempt"] == 2
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

  defp write_workflow!(project, content) do
    workflow_path = Projects.workflow_path(project)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, content)
  end

  defp seed_failed_attempt!(project_slug, story_id, workspace_path) do
    config = %Config{
      workspace: %{root: Path.join(System.tmp_dir!(), "kollywood_story_controller_workspaces")},
      tracker: %{project_slug: project_slug}
    }

    issue = %{id: story_id, identifier: story_id, title: "Story #{story_id}"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    :ok = RunLogs.append_event(context, %{type: :turn_succeeded, turn: 1, output: "agent output"})
    :ok = RunLogs.append_event(context, %{type: :checks_started, check_count: 1})

    :ok =
      RunLogs.append_event(context, %{
        type: :check_failed,
        check_index: 1,
        command: "test -f ready.txt",
        reason: "missing"
      })

    :ok = RunLogs.append_event(context, %{type: :checks_failed, error_count: 1})

    :ok =
      RunLogs.complete_attempt(context, %{
        status: "failed",
        turn_count: 1,
        workspace_path: workspace_path,
        error: "checks failed"
      })
  end
end
