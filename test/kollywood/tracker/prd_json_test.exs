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

  defp config(path, opts \\ []) do
    %Config{
      tracker: %{
        kind: "prd_json",
        path: path,
        active_states: ["open", "in_progress"],
        terminal_states: ["done", "failed", "cancelled"]
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
