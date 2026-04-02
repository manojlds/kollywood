defmodule Kollywood.Tracker.PrdJsonArchiveTest do
  use ExUnit.Case, async: true

  alias Kollywood.Tracker.PrdJsonArchive

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_prd_archive_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "archive_path companion file", %{root: root} do
    path = Path.join(root, "prd.json")
    assert PrdJsonArchive.archive_path(path) == Path.join(root, "prd.archive.json")
  end

  test "does not archive merged story within 24h", %{root: root} do
    path = Path.join(root, "prd.json")
    merged_at = "2026-04-01T12:00:00Z"
    now = ~U[2026-04-01T13:00:00Z]

    write_prd!(path, [
      merged_story("US-001", merged_at)
    ])

    assert {:ok, 0} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    assert length(stories_in_prd(path)) == 1
    refute File.exists?(PrdJsonArchive.archive_path(path))
  end

  test "archives merged story after 24h and appends to archive file", %{root: root} do
    path = Path.join(root, "prd.json")
    archive_path = PrdJsonArchive.archive_path(path)
    merged_at = "2026-03-30T12:00:00Z"
    now = ~U[2026-04-01T12:00:00Z]

    write_prd!(path, [
      merged_story("US-001", merged_at),
      %{"id" => "US-002", "title" => "Open", "status" => "open", "priority" => 2}
    ])

    assert {:ok, 1} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    active = stories_in_prd(path)
    assert Enum.map(active, & &1["id"]) == ["US-002"]

    assert File.exists?(archive_path)
    archived = stories_in_prd(archive_path)
    assert length(archived) == 1
    assert hd(archived)["id"] == "US-001"
    assert hd(archived)["status"] == "merged"
    assert is_binary(hd(archived)["archivedAt"])
  end

  test "restore_story moves story back to prd and removes from archive", %{root: root} do
    path = Path.join(root, "prd.json")
    archive_path = PrdJsonArchive.archive_path(path)
    merged_at = "2026-03-30T12:00:00Z"
    now = ~U[2026-04-01T12:00:00Z]

    write_prd!(path, [
      merged_story("US-099", merged_at)
    ])

    assert {:ok, 1} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    assert stories_in_prd(path) == []
    assert File.exists?(archive_path)

    assert :ok = PrdJsonArchive.restore_story(path, "US-099")

    restored = stories_in_prd(path)
    assert length(restored) == 1
    assert hd(restored)["id"] == "US-099"
    refute Map.has_key?(hd(restored), "archivedAt")

    assert PrdJsonArchive.list_archived(path) == {:ok, []}
  end

  test "list_archived returns empty when archive missing", %{root: root} do
    path = Path.join(root, "prd.json")
    write_prd!(path, [%{"id" => "US-001", "title" => "X", "status" => "open", "priority" => 1}])
    assert PrdJsonArchive.list_archived(path) == {:ok, []}
  end

  test "reconcile drops archive rows when same id still in prd.json", %{root: root} do
    path = Path.join(root, "prd.json")
    archive_path = PrdJsonArchive.archive_path(path)
    now = ~U[2026-04-01T12:00:00Z]
    recent_merge = "2026-04-01T10:00:00Z"

    write_prd!(path, [
      merged_story("US-DUP", recent_merge)
    ])

    write_prd!(archive_path, [
      Map.put(
        merged_story("US-DUP", "2026-03-30T12:00:00Z"),
        "archivedAt",
        "2026-03-30T18:00:00Z"
      )
    ])

    assert {:ok, 0} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    assert PrdJsonArchive.list_archived(path) == {:ok, []}
    assert length(stories_in_prd(path)) == 1
  end

  test "archives merged story using lastTransition recordedAt when merge fields absent",
       %{root: root} do
    path = Path.join(root, "prd.json")
    now = ~U[2026-04-01T12:00:00Z]

    story = %{
      "id" => "US-LT",
      "title" => "LT",
      "status" => "merged",
      "priority" => 1,
      "passes" => true,
      "internalMetadata" => %{
        "lastTransition" => %{
          "event" => "some_other_event",
          "recordedAt" => "2026-03-30T12:00:00Z"
        }
      }
    }

    write_prd!(path, [story])

    assert {:ok, 1} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    assert stories_in_prd(path) == []
  end

  test "archives merged story using updatedAt when merge timestamps absent", %{root: root} do
    path = Path.join(root, "prd.json")
    now = ~U[2026-04-01T12:00:00Z]

    write_prd!(path, [
      %{
        "id" => "US-UP",
        "title" => "Up",
        "status" => "merged",
        "priority" => 1,
        "passes" => true,
        "updatedAt" => "2026-03-30T12:00:00Z"
      }
    ])

    assert {:ok, 1} =
             PrdJsonArchive.archive_stale_merged(path, now: now, min_age_seconds: 24 * 3600)

    assert stories_in_prd(path) == []
  end

  defp merged_story(id, merged_at) do
    %{
      "id" => id,
      "title" => "Merged #{id}",
      "status" => "merged",
      "priority" => 1,
      "passes" => true,
      "mergedAt" => merged_at
    }
  end

  defp write_prd!(path, stories) do
    prd = %{
      "project" => "test",
      "branchName" => "main",
      "description" => "test",
      "userStories" => stories
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(prd, pretty: true) <> "\n")
  end

  defp stories_in_prd(path) do
    {:ok, content} = File.read(path)
    {:ok, map} = Jason.decode(content)
    map["userStories"]
  end
end
