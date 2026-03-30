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

    _output = capture_io(fn -> Prd.run(["set-status", "US-010", "failed", "--path", path]) end)

    story = find_story!(path, "US-010")
    assert story["status"] == "failed"
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

  test "reset moves story to draft and clears previous run metadata", %{root: root} do
    path = Path.join(root, "prd.json")
    workspace_root = Path.join(root, "workspaces")
    workspace_path = Path.join(workspace_root, "US-200")
    File.mkdir_p!(workspace_path)

    write_prd!(path, [
      %{
        "id" => "US-200",
        "title" => "Retry story",
        "priority" => 1,
        "status" => "failed",
        "passes" => false,
        "startedAt" => "2026-03-24T00:00:00Z",
        "completedAt" => "2026-03-24T00:10:00Z",
        "lastRunAttempt" => 4,
        "lastError" => "timeout",
        "lastRun" => %{"status" => "failed"},
        "resumable" => true,
        "pr_url" => "https://example.test/pulls/200",
        "internalMetadata" => %{"lastFailure" => %{"reason" => "timeout"}},
        "notes" => "older note"
      }
    ])

    _output = capture_io(fn -> Prd.run(["reset", "US-200", "--path", path]) end)

    story = find_story!(path, "US-200")
    assert story["status"] == "draft"
    assert story["passes"] == false
    refute Map.has_key?(story, "startedAt")
    refute Map.has_key?(story, "completedAt")
    refute Map.has_key?(story, "lastRunAttempt")
    refute Map.has_key?(story, "lastAttempt")
    refute Map.has_key?(story, "lastError")
    refute Map.has_key?(story, "lastRun")
    refute Map.has_key?(story, "resumable")
    refute Map.has_key?(story, "pr_url")
    refute Map.has_key?(story, "internalMetadata")
    assert story["notes"] == "older note"
    assert File.exists?(workspace_path)
  end

  test "rerun alias supports clearing notes", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-201",
        "title" => "Retry with clear notes",
        "priority" => 1,
        "status" => "failed",
        "notes" => "note to clear"
      }
    ])

    _output =
      capture_io(fn ->
        Prd.run(["rerun", "US-201", "--path", path, "--clear-notes"])
      end)

    story = find_story!(path, "US-201")
    assert story["status"] == "draft"
    assert story["notes"] == ""
  end

  test "reset can remove worktree when fresh-worktree is requested", %{root: root} do
    path = Path.join(root, "prd.json")
    workspace_root = Path.join(root, "workspaces")
    workspace_path = Path.join(workspace_root, "US-202")

    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "temp.txt"), "temp")

    write_prd!(path, [
      %{
        "id" => "US-202",
        "title" => "Fresh worktree story",
        "priority" => 1,
        "status" => "failed"
      }
    ])

    _output =
      capture_io(fn ->
        Prd.run([
          "reset",
          "US-202",
          "--path",
          path,
          "--fresh-worktree",
          "--workspace-root",
          workspace_root
        ])
      end)

    refute File.exists?(workspace_path)

    story = find_story!(path, "US-202")
    assert story["status"] == "draft"
    assert story["passes"] == false
  end

  test "reset --fresh-worktree prunes stale git worktree metadata", %{root: root} do
    kollywood_home = Path.join(root, "kollywood-home")
    old_home = System.get_env("KOLLYWOOD_HOME")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    on_exit(fn ->
      if old_home do
        System.put_env("KOLLYWOOD_HOME", old_home)
      else
        System.delete_env("KOLLYWOOD_HOME")
      end
    end)

    slug = "sample"
    tracker_path = Kollywood.ServiceConfig.project_tracker_path(slug)
    workspace_root = Kollywood.ServiceConfig.project_workspace_root(slug)
    source_repo = Kollywood.ServiceConfig.project_repos_path(slug)
    workspace_path = Path.join(workspace_root, "US-203")

    setup_git_repo!(source_repo)
    run_git!(["worktree", "add", "-b", "kollywood/US-203", workspace_path], source_repo)
    assert File.dir?(workspace_path)

    File.rm_rf!(workspace_path)
    refute File.dir?(workspace_path)

    write_prd!(tracker_path, [
      %{
        "id" => "US-203",
        "title" => "Stale worktree",
        "priority" => 1,
        "status" => "failed"
      }
    ])

    _output =
      capture_io(fn ->
        Prd.run([
          "reset",
          "US-203",
          "--path",
          tracker_path,
          "--fresh-worktree",
          "--workspace-root",
          workspace_root
        ])
      end)

    refute File.exists?(workspace_path)

    {branch_output, 0} =
      System.cmd("git", ["branch", "--list", "kollywood/US-203"],
        cd: source_repo,
        stderr_to_stdout: true
      )

    assert String.trim(branch_output) == ""

    {worktree_output, 0} =
      System.cmd("git", ["worktree", "list", "--porcelain"],
        cd: source_repo,
        stderr_to_stdout: true
      )

    refute worktree_output =~ "kollywood/US-203"
    refute worktree_output =~ "US-203"
  end

  test "validate succeeds for valid PRD and prints summary", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Story A", "priority" => 1, "status" => "open"},
      %{
        "id" => "US-002",
        "title" => "Story B",
        "priority" => 2,
        "status" => "in_progress",
        "dependsOn" => ["US-001"]
      },
      %{"id" => "US-003", "title" => "Story C", "priority" => 3, "status" => "done"}
    ])

    output = capture_io(fn -> Prd.run(["validate", "--path", path]) end)

    assert output =~ "PRD is valid"
    assert output =~ "total_stories=3"
    assert output =~ "active_stories=2"
  end

  test "validate rejects non-object top-level JSON", %{root: root} do
    path = Path.join(root, "prd.json")

    File.write!(path, Jason.encode!([%{"id" => "US-001"}]))

    assert_raise Mix.Error, ~r/must contain a JSON object/i, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects missing userStories array", %{root: root} do
    path = Path.join(root, "prd.json")

    File.write!(
      path,
      Jason.encode!(
        %{
          "project" => "kollywood",
          "branchName" => "test",
          "description" => "test fixture"
        },
        pretty: true
      )
    )

    assert_raise Mix.Error, ~r/missing a valid userStories array/i, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects malformed JSON with a parse error", %{root: root} do
    path = Path.join(root, "prd.json")

    File.write!(path, "{\"userStories\": [}\n")

    assert_raise Mix.Error, ~r/Failed to parse PRD JSON:/, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects invalid statuses", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Story A", "priority" => 1, "status" => "blocked"}
    ])

    assert_raise Mix.Error, ~r/invalid status/i, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects broken dependencies", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-010",
        "title" => "Story with bad dependency",
        "priority" => 1,
        "status" => "open",
        "dependsOn" => ["US-999"]
      }
    ])

    assert_raise Mix.Error, ~r/depends on unknown story "US-999"/, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects duplicate story ids", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => "US-001", "title" => "Story A", "priority" => 1, "status" => "open"},
      %{"id" => "US-001", "title" => "Story B", "priority" => 2, "status" => "done"}
    ])

    assert_raise Mix.Error, ~r/duplicate id/i, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects empty story ids", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{"id" => " ", "title" => "Story A", "priority" => 1, "status" => "open"}
    ])

    assert_raise Mix.Error, ~r/id must be a non-empty string/i, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  test "validate rejects self dependencies", %{root: root} do
    path = Path.join(root, "prd.json")

    write_prd!(path, [
      %{
        "id" => "US-020",
        "title" => "Self dependency",
        "priority" => 1,
        "status" => "open",
        "dependsOn" => ["US-020"]
      }
    ])

    assert_raise Mix.Error, ~r/cannot depend on itself/, fn ->
      capture_io(fn -> Prd.run(["validate", "--path", path]) end)
    end
  end

  defp setup_git_repo!(repo) do
    File.mkdir_p!(repo)
    run_git!(["init", "-b", "main"], repo)
    run_git!(["config", "user.email", "test@test.com"], repo)
    run_git!(["config", "user.name", "Test"], repo)

    File.write!(Path.join(repo, "README.md"), "# Test")
    run_git!(["add", "."], repo)
    run_git!(["commit", "-m", "init"], repo)
  end

  defp run_git!(args, cwd) do
    {output, exit_code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

    if exit_code != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{cwd}: #{String.trim(output)}")
    end

    output
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
