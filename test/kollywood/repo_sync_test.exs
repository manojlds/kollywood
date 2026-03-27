defmodule Kollywood.RepoSyncTest do
  use ExUnit.Case, async: true

  alias Kollywood.RepoSync

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_repo_sync_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "resets to origin/<branch> when available", %{root: root} do
    %{work: work} = setup_remote_repo(root, "main")

    File.write!(Path.join(work, "local_only.txt"), "drift\n")
    run_git!(["add", "local_only.txt"], work)
    run_git!(["commit", "-m", "local drift"], work)

    assert :ok = RepoSync.sync(work, "main")
    assert git_ref(work, "HEAD") == git_ref(work, "origin/main")
    refute File.exists?(Path.join(work, "local_only.txt"))
  end

  test "falls back to local branch when no remote exists", %{root: root} do
    repo = Path.join(root, "local_repo")
    File.mkdir_p!(repo)

    run_git!(["init"], repo)
    configure_git_identity!(repo)
    run_git!(["checkout", "-b", "main"], repo)

    tracked_file = Path.join(repo, "tracked.txt")
    File.write!(tracked_file, "v1\n")
    run_git!(["add", "tracked.txt"], repo)
    run_git!(["commit", "-m", "init"], repo)

    File.write!(tracked_file, "v2\n")

    assert :ok = RepoSync.sync(repo, "main")
    assert File.read!(tracked_file) == "v1\n"
    assert clean_worktree?(repo)
  end

  test "uses origin/HEAD when configured branch does not exist", %{root: root} do
    %{work: work} = setup_remote_repo(root, "trunk")

    File.write!(Path.join(work, "local_only.txt"), "drift\n")
    run_git!(["add", "local_only.txt"], work)
    run_git!(["commit", "-m", "local drift"], work)

    assert :ok = RepoSync.sync(work, "main")
    assert git_ref(work, "HEAD") == git_ref(work, "origin/trunk")
    refute File.exists?(Path.join(work, "local_only.txt"))
  end

  test "returns an error for non-git directories", %{root: root} do
    plain_dir = Path.join(root, "plain")
    File.mkdir_p!(plain_dir)

    assert {:error, reason} = RepoSync.sync(plain_dir, "main")
    assert reason =~ "not a git repository"
  end

  defp setup_remote_repo(root, default_branch) do
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed")
    work = Path.join(root, "work")

    run_git!(["init", "--bare", origin], root)
    run_git!(["clone", origin, seed], root)

    configure_git_identity!(seed)
    run_git!(["checkout", "-b", default_branch], seed)

    File.write!(Path.join(seed, "README.md"), "# Seed\n")
    run_git!(["add", "README.md"], seed)
    run_git!(["commit", "-m", "init"], seed)
    run_git!(["push", "-u", "origin", default_branch], seed)

    run_git!(["symbolic-ref", "HEAD", "refs/heads/#{default_branch}"], origin)

    run_git!(["clone", origin, work], root)
    configure_git_identity!(work)

    %{origin: origin, work: work}
  end

  defp configure_git_identity!(path) do
    run_git!(["config", "user.email", "test@example.com"], path)
    run_git!(["config", "user.name", "Test"], path)
  end

  defp clean_worktree?(path) do
    {output, 0} = System.cmd("git", ["status", "--porcelain"], cd: path, stderr_to_stdout: true)
    String.trim(output) == ""
  end

  defp git_ref(path, ref) do
    {output, 0} = System.cmd("git", ["rev-parse", ref], cd: path, stderr_to_stdout: true)
    String.trim(output)
  end

  defp run_git!(args, cwd) do
    {output, code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

    if code != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{cwd}: #{String.trim(output)}")
    end

    output
  end
end
