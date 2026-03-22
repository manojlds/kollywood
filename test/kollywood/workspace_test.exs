defmodule Kollywood.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Kollywood.Workspace

  @no_hooks %{after_create: nil, before_run: nil, after_run: nil, before_remove: nil}

  setup do
    root = Path.join(System.tmp_dir!(), "kollywood_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    config = %{
      workspace: %{root: root, strategy: :clone},
      hooks: @no_hooks
    }

    %{root: root, config: config}
  end

  # --- Clone strategy ---

  test "creates clone workspace for an issue", %{root: root, config: config} do
    assert {:ok, workspace} = Workspace.create_for_issue("ABC-123", config)
    assert workspace.key == "ABC-123"
    assert workspace.path == Path.join(root, "ABC-123")
    assert workspace.strategy == :clone
    assert File.dir?(workspace.path)
  end

  test "reuses existing workspace", %{config: config} do
    {:ok, ws1} = Workspace.create_for_issue("ABC-123", config)
    File.write!(Path.join(ws1.path, "marker.txt"), "exists")

    {:ok, ws2} = Workspace.create_for_issue("ABC-123", config)
    assert ws1.path == ws2.path
    assert File.exists?(Path.join(ws2.path, "marker.txt"))
  end

  test "sanitizes identifier to safe directory name" do
    assert Workspace.sanitize_key("ABC-123") == "ABC-123"
    assert Workspace.sanitize_key("feat/my branch") == "feat_my_branch"
    assert Workspace.sanitize_key("../../etc/passwd") == ".._.._etc_passwd"
    assert Workspace.sanitize_key("normal.name-123") == "normal.name-123"
  end

  test "runs after_create hook on new workspace", %{root: root} do
    config = %{
      workspace: %{root: root, strategy: :clone},
      hooks: %{@no_hooks | after_create: "touch hook_ran.txt"}
    }

    {:ok, workspace} = Workspace.create_for_issue("HOOK-1", config)
    assert File.exists?(Path.join(workspace.path, "hook_ran.txt"))
  end

  test "fails on after_create hook failure and cleans up", %{root: root} do
    config = %{
      workspace: %{root: root, strategy: :clone},
      hooks: %{@no_hooks | after_create: "exit 1"}
    }

    assert {:error, _reason} = Workspace.create_for_issue("FAIL-1", config)
    refute File.dir?(Path.join(root, "FAIL-1"))
  end

  test "runs before_run hook", %{config: config} do
    {:ok, workspace} = Workspace.create_for_issue("RUN-1", config)
    hooks = %{@no_hooks | before_run: "touch before_ran.txt"}

    assert :ok = Workspace.before_run(workspace, hooks)
    assert File.exists?(Path.join(workspace.path, "before_ran.txt"))
  end

  test "before_run returns error on failure", %{config: config} do
    {:ok, workspace} = Workspace.create_for_issue("RUN-2", config)
    hooks = %{@no_hooks | before_run: "exit 42"}

    assert {:error, msg} = Workspace.before_run(workspace, hooks)
    assert msg =~ "42"
  end

  test "after_run ignores failures", %{config: config} do
    {:ok, workspace} = Workspace.create_for_issue("RUN-3", config)
    hooks = %{@no_hooks | after_run: "exit 1"}

    assert :ok = Workspace.after_run(workspace, hooks)
  end

  test "remove deletes workspace directory", %{config: config} do
    {:ok, workspace} = Workspace.create_for_issue("DEL-1", config)
    assert File.dir?(workspace.path)

    Workspace.remove(workspace, @no_hooks)
    refute File.dir?(workspace.path)
  end

  test "remove runs before_remove hook", %{config: config} do
    {:ok, workspace} = Workspace.create_for_issue("DEL-2", config)

    marker = Path.join(System.tmp_dir!(), "del2_marker_#{System.unique_integer([:positive])}")
    hooks = %{@no_hooks | before_remove: "touch #{marker}"}

    Workspace.remove(workspace, hooks)
    assert File.exists?(marker)
    File.rm(marker)
  end

  test "expands ~ in workspace root" do
    config = %{
      workspace: %{
        root: "~/kollywood_test_tilde_#{System.unique_integer([:positive])}",
        strategy: :clone
      },
      hooks: @no_hooks
    }

    {:ok, workspace} = Workspace.create_for_issue("TILDE-1", config)
    assert String.starts_with?(workspace.path, System.user_home!())
    refute workspace.path =~ "~"
    File.rm_rf!(workspace.root)
  end

  # --- Worktree strategy ---

  defp setup_git_repo(root) do
    repo = Path.join(root, "source_repo")
    File.mkdir_p!(repo)
    System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: repo)
    System.cmd("git", ["config", "user.name", "Test"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: repo)
    System.cmd("git", ["commit", "-m", "init"], cd: repo, stderr_to_stdout: true)
    repo
  end

  test "creates worktree workspace", %{root: root} do
    source = setup_git_repo(root)
    wt_root = Path.join(root, "worktrees")

    config = %{
      workspace: %{root: wt_root, strategy: :worktree, source: source, branch_prefix: "kw/"},
      hooks: @no_hooks
    }

    assert {:ok, workspace} = Workspace.create_for_issue("WT-1", config)
    assert workspace.strategy == :worktree
    assert workspace.branch == "kw/WT-1"
    assert File.dir?(workspace.path)
    assert File.exists?(Path.join(workspace.path, "README.md"))
  end

  test "reuses existing worktree", %{root: root} do
    source = setup_git_repo(root)
    wt_root = Path.join(root, "worktrees")

    config = %{
      workspace: %{root: wt_root, strategy: :worktree, source: source, branch_prefix: "kw/"},
      hooks: @no_hooks
    }

    {:ok, ws1} = Workspace.create_for_issue("WT-2", config)
    File.write!(Path.join(ws1.path, "work.txt"), "done")

    {:ok, ws2} = Workspace.create_for_issue("WT-2", config)
    assert ws1.path == ws2.path
    assert File.exists?(Path.join(ws2.path, "work.txt"))
  end

  test "worktree runs after_create hook", %{root: root} do
    source = setup_git_repo(root)
    wt_root = Path.join(root, "worktrees")

    config = %{
      workspace: %{root: wt_root, strategy: :worktree, source: source, branch_prefix: "kw/"},
      hooks: %{@no_hooks | after_create: "touch hook_ran.txt"}
    }

    {:ok, workspace} = Workspace.create_for_issue("WT-3", config)
    assert File.exists?(Path.join(workspace.path, "hook_ran.txt"))
  end

  test "worktree cleans up on hook failure", %{root: root} do
    source = setup_git_repo(root)
    wt_root = Path.join(root, "worktrees")

    config = %{
      workspace: %{root: wt_root, strategy: :worktree, source: source, branch_prefix: "kw/"},
      hooks: %{@no_hooks | after_create: "exit 1"}
    }

    assert {:error, _} = Workspace.create_for_issue("WT-4", config)
    refute File.dir?(Path.join(wt_root, "WT-4"))

    # Branch should also be cleaned up
    {branches, 0} = System.cmd("git", ["branch"], cd: source, stderr_to_stdout: true)
    refute branches =~ "kw/WT-4"
  end

  test "removes worktree and branch", %{root: root} do
    source = setup_git_repo(root)
    wt_root = Path.join(root, "worktrees")

    config = %{
      workspace: %{root: wt_root, strategy: :worktree, source: source, branch_prefix: "kw/"},
      hooks: @no_hooks
    }

    {:ok, workspace} = Workspace.create_for_issue("WT-5", config)
    assert File.dir?(workspace.path)

    Workspace.remove(workspace, @no_hooks)
    refute File.dir?(workspace.path)

    {branches, 0} = System.cmd("git", ["branch"], cd: source, stderr_to_stdout: true)
    refute branches =~ "kw/WT-5"
  end
end
