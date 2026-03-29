defmodule Kollywood.StepRetryTest do
  use Kollywood.DataCase, async: false

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.ServiceConfig
  alias Kollywood.StepRetry
  alias Kollywood.Workspace

  @no_hooks %{after_create: nil, before_run: nil, after_run: nil, before_remove: nil}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_step_retry_test_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    repo_root = Path.join(root, "repo")
    File.mkdir_p!(repo_root)

    {:ok, project} =
      Projects.create_project(%{
        name: "Step Retry #{System.unique_integer([:positive])}",
        slug: "step-retry-#{System.unique_integer([:positive])}",
        provider: :local,
        repository: repo_root
      })

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)
    end)

    %{root: root, project: project, repo_root: repo_root}
  end

  test "retrying checks creates a linked run attempt and skips agent turns", %{
    root: root,
    project: project
  } do
    write_tracker!(project, [
      %{"id" => "US-CHECKS-SUCCESS", "title" => "Checks", "status" => "failed"}
    ])

    write_clone_checks_workflow!(project)

    workspace_path = Path.join(root, "checks-workspace-success")
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "ready.txt"), "ok\n")

    source_context =
      prepare_failed_attempt!(
        project,
        "US-CHECKS-SUCCESS",
        workspace_path,
        [
          %{type: :turn_succeeded, turn: 1, output: "agent output"},
          %{type: :checks_started, check_count: 1},
          %{type: :check_failed, check_index: 1, command: "test -f ready.txt", reason: "missing"},
          %{type: :checks_failed, error_count: 1}
        ],
        "checks failed"
      )

    assert {:ok, result} =
             StepRetry.retry(project, "US-CHECKS-SUCCESS", source_context.attempt, "checks")

    assert result.parent_attempt == source_context.attempt
    assert result.retry_step == "checks"
    assert result.attempt == source_context.attempt + 1

    latest = resolve_attempt!(project, "US-CHECKS-SUCCESS", result.attempt)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "checks"
    assert latest.metadata["status"] == "ok"

    event_types = read_event_types(latest.files.events)
    assert "checks_started" in event_types
    assert "checks_passed" in event_types
    assert "publish_skipped" in event_types
    refute "turn_started" in event_types
    refute "session_started" in event_types

    story = read_story!(project, "US-CHECKS-SUCCESS")
    assert story["status"] == "done"
    assert get_in(story, ["lastRun", "run_logs", "attempt"]) == result.attempt
    assert story["lastError"] in [nil, ""]
  end

  test "retrying checks applies persisted story execution overrides to run settings", %{
    root: root,
    project: project
  } do
    story_id = "US-CHECKS-OVERRIDES"

    write_tracker!(project, [
      %{
        "id" => story_id,
        "title" => "Checks",
        "status" => "failed",
        "settings" => %{
          "execution" => %{
            "agent_kind" => "cursor",
            "review_agent_kind" => "claude",
            "review_max_cycles" => 5
          }
        }
      }
    ])

    write_clone_checks_workflow!(project)

    workspace_path = Path.join(root, "checks-workspace-overrides")
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "ready.txt"), "ok\n")

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace_path,
        [
          %{type: :turn_succeeded, turn: 1, output: "agent output"},
          %{type: :checks_started, check_count: 1},
          %{type: :check_failed, check_index: 1, command: "test -f ready.txt", reason: "missing"},
          %{type: :checks_failed, error_count: 1}
        ],
        "checks failed"
      )

    assert {:ok, result} = StepRetry.retry(project, story_id, source_context.attempt, "checks")

    latest = resolve_attempt!(project, story_id, result.attempt)
    run_settings = latest.metadata["run_settings"]
    story_overrides = run_settings["story_overrides"]

    assert run_settings["agent_kind"] == "cursor"
    assert run_settings["review_agent_kind"] == "claude"
    assert run_settings["review_max_cycles"] == 1
    assert story_overrides["agent_kind"] == "cursor"
    assert story_overrides["review_agent_kind"] == "claude"
    assert story_overrides["review_max_cycles"] == 5
  end

  test "retrying checks records a failed linked attempt when checks fail again", %{
    root: root,
    project: project
  } do
    write_tracker!(project, [
      %{"id" => "US-CHECKS-FAIL", "title" => "Checks", "status" => "failed"}
    ])

    write_clone_checks_workflow!(project)

    workspace_path = Path.join(root, "checks-workspace-fail")
    File.mkdir_p!(workspace_path)

    source_context =
      prepare_failed_attempt!(
        project,
        "US-CHECKS-FAIL",
        workspace_path,
        [
          %{type: :turn_succeeded, turn: 1, output: "agent output"},
          %{type: :checks_started, check_count: 1},
          %{type: :check_failed, check_index: 1, command: "test -f ready.txt", reason: "missing"},
          %{type: :checks_failed, error_count: 1}
        ],
        "checks failed"
      )

    assert {:error, reason} =
             StepRetry.retry(project, "US-CHECKS-FAIL", source_context.attempt, :checks)

    assert reason =~ "required checks failed"

    failed_attempt = source_context.attempt + 1
    latest = resolve_attempt!(project, "US-CHECKS-FAIL", failed_attempt)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "checks"
    assert latest.metadata["status"] == "failed"
    assert is_binary(latest.metadata["error"])
    assert latest.metadata["error"] =~ "required checks failed"

    original = resolve_attempt!(project, "US-CHECKS-FAIL", source_context.attempt)
    assert original.metadata["status"] == "failed"

    story = read_story!(project, "US-CHECKS-FAIL")
    assert story["status"] == "in_progress"
    assert story["lastError"] =~ "required checks failed"
    assert story["lastRunAttempt"] == failed_attempt
  end

  test "retrying review skips agent turns and checks, then publishes", %{
    root: root,
    project: project
  } do
    story_id = "US-REVIEW-SUCCESS"
    write_tracker!(project, [%{"id" => story_id, "title" => "Review", "status" => "failed"}])

    review_cli_path = write_review_cli!(root, "pass")
    write_clone_review_workflow!(project, review_cli_path)

    workspace_path = Path.join(root, "review-workspace-success")
    File.mkdir_p!(workspace_path)

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace_path,
        [
          %{type: :review_started, cycle: 1},
          %{type: :review_failed, cycle: 1, reason: "needs updates"}
        ],
        "review failed"
      )

    assert {:ok, result} = StepRetry.retry(project, story_id, source_context.attempt, "review")
    assert result.retry_step == "review"

    latest = resolve_attempt!(project, story_id, result.attempt)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "review"
    assert latest.metadata["status"] == "ok"

    event_types = read_event_types(latest.files.events)
    assert "review_started" in event_types
    assert "review_passed" in event_types
    assert "publish_skipped" in event_types
    refute "turn_started" in event_types
    refute "checks_started" in event_types
  end

  test "retrying review records linked failure when review fails again", %{
    root: root,
    project: project
  } do
    story_id = "US-REVIEW-FAIL"
    write_tracker!(project, [%{"id" => story_id, "title" => "Review", "status" => "failed"}])

    review_cli_path = write_review_cli!(root, "fail")
    write_clone_review_workflow!(project, review_cli_path)

    workspace_path = Path.join(root, "review-workspace-fail")
    File.mkdir_p!(workspace_path)

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace_path,
        [
          %{type: :review_started, cycle: 1},
          %{type: :review_failed, cycle: 1, reason: "needs updates"}
        ],
        "review failed"
      )

    assert {:error, reason} = StepRetry.retry(project, story_id, source_context.attempt, "review")
    assert reason =~ "needs updates"

    latest = resolve_attempt!(project, story_id, source_context.attempt + 1)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "review"
    assert latest.metadata["status"] == "failed"
    assert latest.metadata["error"] =~ "needs updates"

    story = read_story!(project, story_id)
    assert story["status"] == "in_progress"
    assert story["lastError"] =~ "needs updates"
  end

  test "retrying review requires checks outputs when checks are configured", %{
    root: root,
    project: project
  } do
    story_id = "US-REVIEW-MISSING-CHECKS"
    write_tracker!(project, [%{"id" => story_id, "title" => "Review", "status" => "failed"}])

    review_cli_path = write_review_cli!(root, "pass")

    write_workflow!(
      project,
      """
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
          enabled: true
          max_cycles: 1
          pass_token: REVIEW_PASS
          fail_token: REVIEW_FAIL
          agent:
            kind: amp
            command: #{review_cli_path}
            args: []
            env: {}
            timeout_ms: 10000
      publish:
        mode: push
      orchestrator:
        retries_enabled: false
      git:
        base_branch: main
      ---

      Work on {{ issue.identifier }}.
      """
    )

    workspace_path = Path.join(root, "review-workspace-missing-checks")
    File.mkdir_p!(workspace_path)

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace_path,
        [
          %{type: :review_started, cycle: 1},
          %{type: :review_failed, cycle: 1, reason: "needs updates"}
        ],
        "review failed"
      )

    assert {:error, reason} = StepRetry.retry(project, story_id, source_context.attempt, "review")
    assert reason =~ "required check outputs are missing"
  end

  test "retrying publish skips checks/review and pushes commits", %{root: root, project: project} do
    story_id = "US-PUBLISH-SUCCESS"
    write_tracker!(project, [%{"id" => story_id, "title" => "Publish", "status" => "failed"}])

    %{origin: origin, source: source, workspaces_root: workspaces_root} =
      setup_worktree_repo!(root)

    write_worktree_publish_workflow!(project, source, workspaces_root)

    workspace =
      create_worktree_workspace!(story_id, source, workspaces_root)
      |> commit_workspace_change!("publish.txt", "publish retry commit\n")

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace.path,
        [
          %{type: :checks_passed, check_count: 1},
          %{type: :review_passed, cycle: 1},
          %{type: :publish_started, branch: workspace.branch, mode: :push},
          %{type: :publish_failed, branch: workspace.branch, reason: "push failed"}
        ],
        "publish failed"
      )

    assert {:ok, result} = StepRetry.retry(project, story_id, source_context.attempt, "publish")
    assert result.retry_step == "publish"

    latest = resolve_attempt!(project, story_id, result.attempt)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "publish"
    assert latest.metadata["status"] == "ok"

    event_types = read_event_types(latest.files.events)
    assert "publish_started" in event_types
    assert "publish_push_succeeded" in event_types
    assert "publish_succeeded" in event_types
    refute "checks_started" in event_types
    refute "review_started" in event_types
    refute "turn_started" in event_types

    {_, show_ref_code} =
      System.cmd("git", [
        "--git-dir",
        origin,
        "show-ref",
        "--verify",
        "refs/heads/#{workspace.branch}"
      ])

    assert show_ref_code == 0
  end

  test "retrying publish records linked failure when publish preconditions fail", %{
    root: root,
    project: project
  } do
    story_id = "US-PUBLISH-FAIL"
    write_tracker!(project, [%{"id" => story_id, "title" => "Publish", "status" => "failed"}])

    %{source: source, workspaces_root: workspaces_root} = setup_worktree_repo!(root)
    write_worktree_publish_workflow!(project, source, workspaces_root)

    workspace = create_worktree_workspace!(story_id, source, workspaces_root)

    source_context =
      prepare_failed_attempt!(
        project,
        story_id,
        workspace.path,
        [
          %{type: :checks_passed, check_count: 1},
          %{type: :review_passed, cycle: 1},
          %{type: :publish_started, branch: workspace.branch, mode: :push},
          %{type: :publish_failed, branch: workspace.branch, reason: "push failed"}
        ],
        "publish failed"
      )

    assert {:error, reason} =
             StepRetry.retry(project, story_id, source_context.attempt, "publish")

    assert reason =~ "no commits found on branch"

    latest = resolve_attempt!(project, story_id, source_context.attempt + 1)
    assert latest.metadata["parent_attempt"] == source_context.attempt
    assert latest.metadata["retry_step"] == "publish"
    assert latest.metadata["status"] == "failed"
    assert latest.metadata["error"] =~ "no commits found on branch"
  end

  defp write_clone_checks_workflow!(project) do
    write_workflow!(
      project,
      """
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
      """
    )
  end

  defp write_clone_review_workflow!(project, review_cli_path) do
    write_workflow!(
      project,
      """
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
          required: []
          timeout_ms: 10000
          fail_fast: true
          max_cycles: 1
        review:
          enabled: true
          max_cycles: 1
          pass_token: REVIEW_PASS
          fail_token: REVIEW_FAIL
          agent:
            kind: amp
            command: #{review_cli_path}
            args: []
            env: {}
            timeout_ms: 10000
      publish:
        mode: push
      orchestrator:
        retries_enabled: false
      git:
        base_branch: main
      ---

      Work on {{ issue.identifier }}.
      """
    )
  end

  defp write_worktree_publish_workflow!(project, source_repo, workspaces_root) do
    write_workflow!(
      project,
      """
      ---
      tracker:
        kind: prd_json
      workspace:
        strategy: worktree
        source: #{source_repo}
        root: #{workspaces_root}
        branch_prefix: kw/
      agent:
        kind: amp
        command: /bin/true
      quality:
        max_cycles: 1
        checks:
          required: []
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
      """
    )
  end

  defp write_workflow!(project, content) do
    path = Projects.workflow_path(project)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp write_tracker!(project, stories) do
    tracker_path = Projects.tracker_path(project)
    File.mkdir_p!(Path.dirname(tracker_path))

    payload = %{
      "project" => "step-retry-test",
      "branchName" => "main",
      "description" => "step retry fixtures",
      "userStories" => stories
    }

    File.write!(tracker_path, Jason.encode!(payload, pretty: true))
  end

  defp prepare_failed_attempt!(project, story_id, workspace_path, events, error_reason) do
    config = %Config{
      workspace: %{root: Path.join(System.tmp_dir!(), "kollywood_step_retry_workspaces")},
      tracker: %{project_slug: project.slug}
    }

    issue = %{id: story_id, identifier: story_id, title: "Story #{story_id}"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    Enum.each(events, fn event ->
      :ok = RunLogs.append_event(context, event)
    end)

    :ok =
      RunLogs.complete_attempt(context, %{
        status: "failed",
        turn_count: 1,
        workspace_path: workspace_path,
        error: error_reason
      })

    context
  end

  defp resolve_attempt!(project, story_id, attempt) do
    project_root = ServiceConfig.project_data_dir(project.slug)
    {:ok, resolved} = RunLogs.resolve_attempt(project_root, story_id, attempt)
    resolved
  end

  defp read_event_types(events_path) do
    events_path
    |> File.stream!([], :line)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn json ->
      {:ok, decoded} = Jason.decode(json)
      decoded["type"]
    end)
  end

  defp read_story!(project, story_id) do
    tracker_path = Projects.tracker_path(project)
    {:ok, content} = File.read(tracker_path)
    {:ok, decoded} = Jason.decode(content)

    decoded
    |> Map.fetch!("userStories")
    |> Enum.find(fn story -> story["id"] == story_id end)
  end

  defp write_review_cli!(root, verdict) when verdict in ["pass", "fail"] do
    path = Path.join(root, "fake_review_#{verdict}_#{System.unique_integer([:positive])}.sh")

    summary =
      case verdict do
        "pass" -> "review complete"
        "fail" -> "needs updates"
      end

    File.write!(path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"
    review_json_path=$(printf '%s' "$prompt" | grep -oP 'Write your review to `\\K[^`]+' || echo "/tmp/review.json")
    printf '{"verdict":"#{verdict}","summary":"#{summary}","findings":[]}' > "$review_json_path"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp setup_worktree_repo!(root) do
    origin = Path.join(root, "origin.git")
    seed = Path.join(root, "seed_repo")
    source = Path.join(root, "source_repo")
    workspaces_root = Path.join(root, "workspaces")

    File.mkdir_p!(origin)
    git!(["init", "--bare"], origin)
    git!(["clone", origin, seed], root)

    git!(["config", "user.email", "test@test.com"], seed)
    git!(["config", "user.name", "Test"], seed)
    git!(["checkout", "-b", "main"], seed)
    File.write!(Path.join(seed, "README.md"), "# Seed\n")
    git!(["add", "."], seed)
    git!(["commit", "-m", "seed"], seed)
    git!(["push", "-u", "origin", "main"], seed)

    git!(["clone", origin, source], root)
    git!(["checkout", "main"], source)

    %{origin: origin, source: source, workspaces_root: workspaces_root}
  end

  defp create_worktree_workspace!(story_id, source, workspaces_root) do
    config = %Config{
      workspace: %{
        strategy: :worktree,
        source: source,
        root: workspaces_root,
        branch_prefix: "kw/"
      },
      hooks: @no_hooks
    }

    {:ok, workspace} = Workspace.create_for_issue(story_id, config)
    workspace
  end

  defp commit_workspace_change!(workspace, filename, contents) do
    git!(["config", "user.email", "test@test.com"], workspace.path)
    git!(["config", "user.name", "Test"], workspace.path)
    File.write!(Path.join(workspace.path, filename), contents)
    git!(["add", filename], workspace.path)
    git!(["commit", "-m", "step retry publish change"], workspace.path)
    workspace
  end

  defp git!(args, cwd) do
    {output, code} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)

    if code != 0 do
      flunk("git #{Enum.join(args, " ")} failed in #{cwd}: #{String.trim(output)}")
    end

    output
  end
end
