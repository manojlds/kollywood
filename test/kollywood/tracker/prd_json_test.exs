defmodule Kollywood.Tracker.PrdJsonTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config
  alias Kollywood.Tracker.PrdJson

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_prd_tracker_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "lists active stories and includes dependency blockers", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Foundation", "status" => "done", "priority" => 1},
      %{
        "id" => "US-002",
        "title" => "Feature",
        "status" => "open",
        "priority" => 2,
        "dependsOn" => ["US-001"],
        "acceptanceCriteria" => ["passes tests"]
      },
      %{
        "id" => "US-003",
        "title" => "Blocked story",
        "status" => "open",
        "priority" => 3,
        "dependsOn" => ["US-004"]
      },
      %{
        "id" => "US-004",
        "title" => "In progress dep",
        "status" => "in_progress",
        "priority" => 4
      }
    ])

    assert {:ok, issues} = PrdJson.list_active_issues(config(path))

    assert Enum.map(issues, & &1.id) == ["US-002", "US-003", "US-004"]

    issue_two = Enum.find(issues, fn issue -> issue.id == "US-002" end)
    issue_three = Enum.find(issues, fn issue -> issue.id == "US-003" end)

    assert issue_two.blocked_by == [
             %{
               id: "US-001",
               identifier: "US-001",
               title: "Foundation",
               state: "done"
             }
           ]

    assert issue_three.blocked_by == [
             %{
               id: "US-004",
               identifier: "US-004",
               title: "In progress dep",
               state: "in_progress"
             }
           ]
  end

  test "updates story status for in_progress, failed and done", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-010", "title" => "Dogfood story", "status" => "open", "priority" => 1}
    ])

    cfg = config(path)

    assert :ok = PrdJson.claim_issue(cfg, "US-010")
    assert :ok = PrdJson.mark_in_progress(cfg, "US-010")
    assert story_status(path, "US-010") == "in_progress"

    assert :ok = PrdJson.mark_failed(cfg, "US-010", "forced failure", 2)

    story_after_failure = story(path, "US-010")
    assert story_after_failure["status"] == "in_progress"
    assert String.contains?(story_after_failure["notes"], "attempt 2: forced failure")

    assert :ok = PrdJson.mark_done(cfg, "US-010", %{status: :ok, turn_count: 1})

    story_after_done = story(path, "US-010")
    assert story_after_done["status"] == "done"
    assert story_after_done["passes"] == true
    assert is_map(story_after_done["lastRun"])

    assert :ok = PrdJson.mark_merged(cfg, "US-010", %{status: :ok, turn_count: 1})

    story_after_merged = story(path, "US-010")
    assert story_after_merged["status"] == "merged"
    assert story_after_merged["passes"] == true
  end

  test "marks story resumable and keeps in_progress status", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-030",
        "title" => "Resumable story",
        "status" => "in_progress",
        "priority" => 1,
        "completedAt" => "2026-03-27T09:30:00Z",
        "notes" => "existing note"
      }
    ])

    cfg = config(path)

    assert :ok = PrdJson.mark_resumable(cfg, "US-030", %{turn_count: 5})

    saved_story = story(path, "US-030")
    assert saved_story["status"] == "in_progress"
    assert saved_story["resumable"] == true
    assert saved_story["completedAt"] == "2026-03-27T09:30:00Z"
    assert String.contains?(saved_story["notes"], "existing note")

    assert saved_story["notes"] =~
             ~r/\[\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\] continuation scheduled after max turns/
  end

  test "marks story failed when retries are disabled", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-020", "title" => "No retry story", "status" => "open", "priority" => 1}
    ])

    cfg = config(path, retries_enabled: false)

    assert :ok = PrdJson.mark_failed(cfg, "US-020", "no retry mode", 1)

    story_after_failure = story(path, "US-020")
    assert story_after_failure["status"] == "failed"
    assert story_after_failure["passes"] == false
  end

  test "marks story pending_merge and stores pr metadata", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-030", "title" => "Await merge", "status" => "done", "priority" => 1}
    ])

    cfg = config(path)
    pr_url = "https://github.com/acme/kollywood/pull/42"

    assert :ok = PrdJson.mark_pending_merge(cfg, "US-030", %{pr_url: pr_url})

    story_after_pending_merge = story(path, "US-030")
    assert story_after_pending_merge["status"] == "pending_merge"
    assert story_after_pending_merge["pr_url"] == pr_url

    assert story_after_pending_merge["notes"] =~
             ~r/\[\d{4}-\d{2}-\d{2}T[^\]]+\] pending merge: https:\/\/github.com\/acme\/kollywood\/pull\/42/
  end

  test "marks story merged and appends merged note", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-031",
        "title" => "Merge complete",
        "status" => "pending_merge",
        "priority" => 1,
        "resumable" => true,
        "notes" => "existing note"
      }
    ])

    cfg = config(path)

    assert :ok = PrdJson.mark_merged(cfg, "US-031", %{})

    story_after_merge = story(path, "US-031")
    assert story_after_merge["status"] == "merged"
    assert story_after_merge["resumable"] == false
    assert is_binary(story_after_merge["mergedAt"])
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(story_after_merge["mergedAt"])
    assert story_after_merge["notes"] =~ "existing note"
    assert story_after_merge["notes"] =~ ~r/\[\d{4}-\d{2}-\d{2}T[^\]]+\] merged to main/
  end

  test "lists pending_merge stories with pr_url", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-040",
        "title" => "Pending merge story",
        "status" => "pending_merge",
        "priority" => 1,
        "pr_url" => "https://example.test/pulls/40"
      },
      %{
        "id" => "US-041",
        "title" => "Pending merge without url",
        "status" => "pending_merge",
        "priority" => 2
      },
      %{"id" => "US-042", "title" => "Open story", "status" => "open", "priority" => 3}
    ])

    cfg = config(path)

    assert {:ok, issues} = PrdJson.list_pending_merge_issues(cfg)
    assert length(issues) == 1

    issue = hd(issues)
    assert issue.id == "US-040"
    assert issue.state == "pending_merge"
    assert issue.pr_url == "https://example.test/pulls/40"
  end

  test "create, update, and delete story helpers", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-100", "title" => "Base story", "status" => "open", "priority" => 1}
    ])

    assert {:ok, created} =
             PrdJson.create_story(path, %{
               "title" => "Created story",
               "status" => "draft",
               "dependsOn" => "US-100"
             })

    created_id = created["id"]
    assert created["status"] == "draft"

    assert {:ok, updated} =
             PrdJson.update_story(path, created_id, %{
               "title" => "Updated title",
               "status" => "open",
               "priority" => 4
             })

    assert updated["title"] == "Updated title"
    assert updated["status"] == "open"
    assert updated["priority"] == 4

    assert :ok = PrdJson.delete_story(path, created_id)

    assert {:ok, stories} = PrdJson.list_stories(path)
    refute Enum.any?(stories, &(Map.get(&1, "id") == created_id))
  end

  test "manual status updates cannot move to in_progress", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-200", "title" => "Manual transition", "status" => "open", "priority" => 1}
    ])

    assert {:error, reason} = PrdJson.set_manual_status(path, "US-200", "in_progress")
    assert reason =~ "managed by the orchestrator"
  end

  defp config(path, opts \\ []) do
    %Config{
      tracker: %{
        kind: "prd_json",
        path: path,
        active_states: ["open", "in_progress", "pending_merge", "merged"],
        terminal_states: ["done", "merged", "failed", "cancelled"]
      },
      polling: %{},
      workspace: %{},
      hooks: %{},
      agent: %{retries_enabled: Keyword.get(opts, :retries_enabled, true)},
      raw: %{}
    }
  end

  defp write_prd!(path, stories) do
    payload = %{
      "project" => "kollywood",
      "branchName" => "dogfood/prd-json",
      "description" => "Tracker test fixture",
      "userStories" => stories
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp story(path, story_id) do
    {:ok, content} = File.read(path)
    {:ok, decoded} = Jason.decode(content)

    decoded
    |> Map.fetch!("userStories")
    |> Enum.find(fn item -> item["id"] == story_id end)
  end

  defp story_status(path, story_id) do
    path
    |> story(story_id)
    |> Map.fetch!("status")
  end
end
