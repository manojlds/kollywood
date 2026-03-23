defmodule Mix.Tasks.Kollywood.PrdTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Kollywood.Prd

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_prd_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "list shows only active stories by default", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Open", "priority" => 1, "status" => "open"},
      %{"id" => "US-002", "title" => "In progress", "priority" => 2, "status" => "in_progress"},
      %{"id" => "US-003", "title" => "Done", "priority" => 3, "status" => "done"}
    ])

    output = capture_io(fn -> Prd.run(["list", "--path", path]) end)

    assert output =~ "US-001"
    assert output =~ "US-002"
    refute output =~ "US-003"
  end

  test "add creates a story with generated id", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Existing", "priority" => 1, "status" => "open"}
    ])

    output =
      capture_io(fn ->
        Prd.run([
          "add",
          "--path",
          path,
          "--title",
          "New story",
          "--description",
          "implement command",
          "--depends-on",
          "US-001",
          "--acceptance",
          "works",
          "--acceptance",
          "is tested"
        ])
      end)

    assert output =~ "Added story US-002"

    story = find_story!(path, "US-002")
    assert story["title"] == "New story"
    assert story["description"] == "implement command"
    assert story["status"] == "open"
    assert story["dependsOn"] == ["US-001"]
    assert story["acceptanceCriteria"] == ["works", "is tested"]
  end

  test "add initializes missing PRD file", %{root: root} do
    path = Path.join(root, "prd.json")

    _output =
      capture_io(fn ->
        Prd.run(["add", "--path", path, "--title", "Bootstrap story"])
      end)

    assert File.exists?(path)
    assert find_story!(path, "US-001")["title"] == "Bootstrap story"
  end

  test "set-status updates story status and passes flag", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-010", "title" => "Status story", "priority" => 1, "status" => "open"}
    ])

    _output = capture_io(fn -> Prd.run(["set-status", "US-010", "done", "--path", path]) end)

    story = find_story!(path, "US-010")
    assert story["status"] == "done"
    assert story["passes"] == true

    _output = capture_io(fn -> Prd.run(["set-status", "US-010", "open", "--path", path]) end)

    story = find_story!(path, "US-010")
    assert story["status"] == "open"
    assert story["passes"] == false
  end

  test "set-status rejects invalid status", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-100", "title" => "Story", "priority" => 1, "status" => "open"}
    ])

    assert_raise Mix.Error, ~r/Invalid status/, fn ->
      capture_io(fn -> Prd.run(["set-status", "US-100", "blocked", "--path", path]) end)
    end
  end

  defp write_prd!(path, stories) do
    payload = %{
      "project" => "kollywood",
      "branchName" => "test",
      "description" => "test fixture",
      "userStories" => stories
    }

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(payload, pretty: true))
  end

  defp find_story!(path, story_id) do
    {:ok, content} = File.read(path)
    {:ok, decoded} = Jason.decode(content)

    decoded
    |> Map.fetch!("userStories")
    |> Enum.find(fn story -> story["id"] == story_id end)
    |> case do
      nil -> flunk("Expected story #{story_id} in #{path}")
      story -> story
    end
  end
end
