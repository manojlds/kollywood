defmodule Kollywood.Orchestrator.RunLogsTest do
  use ExUnit.Case, async: false

  alias Kollywood.AgentRunner.Result
  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_run_logs_test_#{System.unique_integer([:positive])}"
      )

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(root, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    File.mkdir_p!(root)

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(root)
    end)

    config = %Config{
      workspace: %{root: root},
      tracker: %{path: nil, project_slug: "run-logs-test"}
    }

    issue = %{id: "US-TEST", identifier: "US-TEST", title: "Test issue"}

    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    %{root: root, context: context}
  end

  describe "prepare_attempt/3" do
    test "creates agent.log file in attempt directory", %{context: context} do
      assert File.exists?(context.files.agent)
      assert File.exists?(context.files.tester)
      assert File.exists?(context.files.tester_stdout)
    end

    test "includes agent path in metadata files map", %{context: context} do
      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert Map.has_key?(metadata["files"], "agent")
      assert metadata["files"]["agent"] == context.files.agent
      assert Map.has_key?(metadata["files"], "tester")
      assert metadata["files"]["tester"] == context.files.tester
      assert Map.has_key?(metadata["files"], "testing_json")
      assert metadata["files"]["testing_json"] == context.files.testing_json
      assert Map.has_key?(metadata["files"], "review_cycles_dir")
      assert metadata["files"]["review_cycles_dir"] == context.files.review_cycles_dir
      assert Map.has_key?(metadata["files"], "testing_cycles_dir")
      assert metadata["files"]["testing_cycles_dir"] == context.files.testing_cycles_dir
      assert Map.has_key?(metadata["files"], "testing_report")
      assert metadata["files"]["testing_report"] == context.files.testing_report
      assert Map.has_key?(metadata["files"], "testing_artifacts_dir")
      assert metadata["files"]["testing_artifacts_dir"] == context.files.testing_artifacts_dir
    end

    test "includes agent in tracker_metadata", %{context: context} do
      tracker_meta = RunLogs.tracker_metadata(context)
      assert Map.has_key?(tracker_meta.run_logs.files, :agent)
      assert Map.has_key?(tracker_meta.run_logs.files, :tester)
      assert Map.has_key?(tracker_meta.run_logs.files, :tester_stdout)
      assert Map.has_key?(tracker_meta.run_logs.files, :review_json)
      assert Map.has_key?(tracker_meta.run_logs.files, :review_cycles_dir)
      assert Map.has_key?(tracker_meta.run_logs.files, :testing_json)
      assert Map.has_key?(tracker_meta.run_logs.files, :testing_cycles_dir)
      assert Map.has_key?(tracker_meta.run_logs.files, :testing_report)
      assert Map.has_key?(tracker_meta.run_logs.files, :testing_artifacts_dir)
    end

    test "persists retry mode and provenance in metadata" do
      root =
        Path.join(
          System.tmp_dir!(),
          "kollywood_run_logs_retry_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)

      config = %Config{
        workspace: %{root: root},
        tracker: %{path: nil, project_slug: "run-logs-test"}
      }

      issue = %{id: "US-RETRY", identifier: "US-RETRY", title: "Retry issue"}

      {:ok, context} =
        RunLogs.prepare_attempt(config, issue, 2,
          retry_mode: :agent_continuation,
          retry_provenance: %{
            originating_attempt: 1,
            last_successful_turn: 4,
            failure_reason: "agent timeout"
          }
        )

      metadata = File.read!(context.files.metadata) |> Jason.decode!()

      assert metadata["retry_mode"] == "agent_continuation"
      assert metadata["retry_provenance"]["originating_attempt"] == 1
      assert metadata["retry_provenance"]["last_successful_turn"] == 4
      assert metadata["retry_provenance"]["failure_reason"] == "agent timeout"
    end

    test "exposes retry mode and provenance via tracker metadata" do
      root =
        Path.join(
          System.tmp_dir!(),
          "kollywood_run_logs_tracker_retry_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)

      config = %Config{
        workspace: %{root: root},
        tracker: %{path: nil, project_slug: "run-logs-test"}
      }

      issue = %{id: "US-TRACKER-RETRY", identifier: "US-TRACKER-RETRY", title: "Retry issue"}

      {:ok, context} =
        RunLogs.prepare_attempt(config, issue, 1,
          retry_mode: :agent_continuation,
          retry_provenance: %{
            originating_attempt: 1,
            last_successful_turn: 2,
            failure_reason: "turn failed"
          }
        )

      tracker_meta = RunLogs.tracker_metadata(context)
      assert tracker_meta.retry_mode == "agent_continuation"
      assert tracker_meta.retry_provenance["originating_attempt"] == 1
      assert tracker_meta.retry_provenance["last_successful_turn"] == 2
      assert tracker_meta.run_logs.retry_mode == "agent_continuation"
      assert tracker_meta.run_logs.retry_provenance["failure_reason"] == "turn failed"
    end
  end

  describe "complete_attempt/2" do
    test "stores last_successful_turn derived from turn_succeeded events", %{context: context} do
      now = DateTime.utc_now()

      result = %Result{
        issue_id: "US-TEST",
        identifier: "US-TEST",
        workspace_path: "/tmp/workspace",
        turn_count: 3,
        status: :failed,
        started_at: now,
        ended_at: now,
        last_output: nil,
        events: [
          %{type: :turn_started, turn: 1},
          %{type: :turn_succeeded, turn: 1},
          %{type: "turn_succeeded", turn: "2"},
          %{type: :turn_failed, turn: 3}
        ],
        error: "agent phase failed"
      }

      assert :ok = RunLogs.complete_attempt(context, result)

      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert metadata["turn_count"] == 3
      assert metadata["last_successful_turn"] == 2
      assert metadata["status"] == "failed"
    end

    test "captures testing report metadata when testing_report.json exists", %{context: context} do
      File.mkdir_p!(context.files.testing_artifacts_dir)

      report = %{
        "verdict" => "pass",
        "summary" => "testing complete",
        "checkpoints" => [
          %{"name" => "smoke", "status" => "pass", "details" => "ok"}
        ],
        "artifacts" => [
          %{
            "kind" => "screenshot",
            "path" => "artifacts/testing-success.png",
            "stored_path" => Path.join(context.files.testing_artifacts_dir, "001_smoke.png")
          }
        ]
      }

      File.write!(context.files.testing_report, Jason.encode!(report, pretty: true))

      assert :ok = RunLogs.complete_attempt(context, %{status: :ok, turn_count: 1})

      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert metadata["testing_report"]["verdict"] == "pass"
      assert metadata["testing_report"]["summary"] == "testing complete"
      assert is_list(metadata["testing_artifacts"])
      assert length(metadata["testing_artifacts"]) == 1
      assert hd(metadata["testing_artifacts"])["kind"] == "screenshot"
    end

    test "preserves nil error for successful runs", %{context: context} do
      assert :ok = RunLogs.complete_attempt(context, %{status: :ok, turn_count: 1, error: nil})

      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert metadata["status"] == "ok"
      assert Map.get(metadata, "error") == nil
      assert metadata["run_state"]["phase"] == "finished"
      assert metadata["run_state"]["activity"] == "completed"
    end

    test "persists recovery guidance in metadata from result events", %{context: context} do
      now = DateTime.utc_now()

      result = %Result{
        issue_id: "US-TEST",
        identifier: "US-TEST",
        workspace_path: "/tmp/workspace",
        turn_count: 1,
        status: :failed,
        started_at: now,
        ended_at: now,
        last_output: nil,
        events: [
          %{type: :publish_started, branch: "kw/US-TEST"},
          %{
            type: :publish_failed,
            reason:
              "push failed\nRecovery commands:\n  git -C '/tmp/work' status --short\n  git -C '/tmp/work' push -u origin 'kw/US-TEST'"
          }
        ],
        error: "publish failed"
      }

      assert :ok = RunLogs.complete_attempt(context, result)

      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert metadata["recovery_guidance"]["summary"] == "push failed"

      assert metadata["recovery_guidance"]["commands"] == [
               "git -C '/tmp/work' status --short",
               "git -C '/tmp/work' push -u origin 'kw/US-TEST'"
             ]
    end

    test "persists recovery guidance in metadata from fallback error text", %{context: context} do
      now = DateTime.utc_now()

      result = %Result{
        issue_id: "US-TEST",
        identifier: "US-TEST",
        workspace_path: "/tmp/workspace",
        turn_count: 1,
        status: :failed,
        started_at: now,
        ended_at: now,
        last_output: nil,
        events: [%{type: :run_finished, status: "failed"}],
        error:
          "sync failed\nRecovery commands:\n  git fetch --all --prune\n  git reset --hard origin/main"
      }

      assert :ok = RunLogs.complete_attempt(context, result)

      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert metadata["recovery_guidance"]["summary"] == "sync failed"

      assert metadata["recovery_guidance"]["commands"] == [
               "git fetch --all --prune",
               "git reset --hard origin/main"
             ]
    end
  end

  describe "append_event/2 with turn_succeeded" do
    test "writes output to agent.log with turn separator", %{context: context} do
      event = %{type: :turn_succeeded, turn: 1, output: "Hello from agent", duration_ms: 100}
      assert :ok = RunLogs.append_event(context, event)

      content = File.read!(context.files.agent)
      assert content =~ "--- Turn 1 ---"
      assert content =~ "Hello from agent"
    end

    test "writes multiple turns with separators", %{context: context} do
      RunLogs.append_event(context, %{type: :turn_succeeded, turn: 1, output: "Turn one output"})
      RunLogs.append_event(context, %{type: :turn_succeeded, turn: 2, output: "Turn two output"})

      content = File.read!(context.files.agent)
      assert content =~ "--- Turn 1 ---"
      assert content =~ "Turn one output"
      assert content =~ "--- Turn 2 ---"
      assert content =~ "Turn two output"
    end

    test "does not write to agent.log when output is absent", %{context: context} do
      RunLogs.append_event(context, %{type: :turn_succeeded, turn: 1, duration_ms: 50})

      content = File.read!(context.files.agent)
      assert content == ""
    end

    test "keeps worker log focused on worker event metadata", %{context: context} do
      stream_json =
        ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}})

      event = %{
        type: :turn_succeeded,
        turn: 1,
        duration_ms: 123,
        command: "cursor",
        args: ["agent", "--print", "very long prompt body"],
        output: stream_json,
        raw_output: stream_json
      }

      assert :ok = RunLogs.append_event(context, event)

      worker_log = File.read!(context.files.worker)
      assert worker_log =~ "[worker] turn_succeeded"
      assert worker_log =~ "command=cursor"
      refute worker_log =~ "args="
      refute worker_log =~ "output:"
      refute worker_log =~ "raw_output:"
      refute worker_log =~ "\"type\":\"assistant\""
    end
  end

  describe "append_event/2 with review events" do
    test "writes review_passed output to agent.log", %{context: context} do
      event = %{type: :review_passed, cycle: 1, output: "Review output here"}
      assert :ok = RunLogs.append_event(context, event)

      content = File.read!(context.files.agent)
      assert content =~ "--- Turn 1 ---"
      assert content =~ "Review output here"
    end

    test "writes review_failed output to agent.log", %{context: context} do
      event = %{type: :review_failed, cycle: 2, output: "Review failed output"}
      assert :ok = RunLogs.append_event(context, event)

      content = File.read!(context.files.agent)
      assert content =~ "--- Turn 2 ---"
      assert content =~ "Review failed output"
    end
  end

  describe "append_event/2 with testing events" do
    test "writes testing events to tester.log", %{context: context} do
      event = %{type: :testing_passed, cycle: 1, summary: "Testing complete"}
      assert :ok = RunLogs.append_event(context, event)

      tester_log = File.read!(context.files.tester)
      assert tester_log =~ "[tester] testing_passed"
      assert tester_log =~ "summary=\"Testing complete\""
    end
  end

  describe "append_event/2 with other events" do
    test "does not write to agent.log for non-agent events", %{context: context} do
      RunLogs.append_event(context, %{type: :run_started})
      RunLogs.append_event(context, %{type: :workspace_ready})
      RunLogs.append_event(context, %{type: :check_passed, output: "check output"})

      content = File.read!(context.files.agent)
      assert content == ""
    end

    test "persists structured recovery guidance parsed from reason text", %{context: context} do
      event = %{
        type: :publish_failed,
        reason:
          "push failed\nRecovery commands:\n  git -C '/tmp/work' status --short\n  git -C '/tmp/work' push -u origin 'kw/US-TEST'"
      }

      assert :ok = RunLogs.append_event(context, event)

      [line] = context.files.events |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)

      assert decoded["recovery_guidance"]["summary"] == "push failed"

      assert decoded["recovery_guidance"]["commands"] == [
               "git -C '/tmp/work' status --short",
               "git -C '/tmp/work' push -u origin 'kw/US-TEST'"
             ]

      assert decoded["run_state"]["phase"] == "running"
      assert decoded["run_state"]["activity"] == "blocked"
    end

    test "preserves provided structured recovery guidance payload", %{context: context} do
      event = %{
        type: :publish_failed,
        reason: "push failed",
        recovery_guidance: %{
          summary: "push failed",
          commands: [
            "git -C '/tmp/work' remote -v",
            "git -C '/tmp/work' push -u origin 'kw/US-STRUCTURED'"
          ]
        }
      }

      assert :ok = RunLogs.append_event(context, event)

      [line] = context.files.events |> File.read!() |> String.split("\n", trim: true)
      decoded = Jason.decode!(line)

      assert decoded["recovery_guidance"]["summary"] == "push failed"

      assert decoded["recovery_guidance"]["commands"] == [
               "git -C '/tmp/work' remote -v",
               "git -C '/tmp/work' push -u origin 'kw/US-STRUCTURED'"
             ]
    end
  end

  describe "settings snapshot compatibility" do
    test "returns nil when metadata has no snapshot key" do
      assert RunLogs.settings_snapshot(%{"status" => "ok"}) == nil
    end

    test "list_attempts keeps legacy attempts readable without snapshots", %{context: context} do
      project_root = context.project_root
      story_dir = Path.join([project_root, "run_logs", "US-LEGACY"])
      attempt_dir = Path.join(story_dir, "attempt-0001")
      File.mkdir_p!(attempt_dir)

      metadata = %{
        "story_id" => "US-LEGACY",
        "attempt" => 1,
        "status" => "failed",
        "started_at" => "2026-03-28T00:00:00Z",
        "ended_at" => "2026-03-28T00:00:10Z",
        "error" => "legacy fixture"
      }

      File.write!(Path.join(attempt_dir, "metadata.json"), Jason.encode!(metadata, pretty: true))

      assert {:ok, [attempt]} = RunLogs.list_attempts(project_root, "US-LEGACY")
      assert attempt.metadata["status"] == "failed"
      assert attempt.settings_snapshot == nil
    end
  end

  describe "reconcile_orphaned_step_retries/2" do
    test "marks interrupted step retries as failed and appends attempt_finished", %{root: root} do
      config = %Config{
        workspace: %{root: root},
        tracker: %{path: nil, project_slug: "run-logs-test"}
      }

      issue = %{id: "US-RETRY", identifier: "US-RETRY", title: "Retry issue"}

      {:ok, context} =
        RunLogs.prepare_attempt(config, issue, nil,
          metadata_overrides: %{"parent_attempt" => 1, "retry_step" => "testing"}
        )

      reason = "interrupted during deploy drain restart"

      assert {:ok, 1} =
               RunLogs.reconcile_orphaned_step_retries(context.project_root, reason: reason)

      metadata = context.files.metadata |> File.read!() |> Jason.decode!()
      assert metadata["status"] == "failed"
      assert metadata["error"] == reason
      assert is_binary(metadata["ended_at"])

      lines = context.files.attempts_index |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2

      finished_entry = lines |> List.last() |> Jason.decode!()
      assert finished_entry["event"] == "attempt_finished"
      assert finished_entry["attempt"] == context.attempt
      assert finished_entry["status"] == "failed"
      assert finished_entry["error"] == reason

      assert {:ok, 0} =
               RunLogs.reconcile_orphaned_step_retries(context.project_root, reason: reason)
    end

    test "does not alter non-step running attempts", %{context: context} do
      assert {:ok, 0} = RunLogs.reconcile_orphaned_step_retries(context.project_root)

      metadata = context.files.metadata |> File.read!() |> Jason.decode!()
      assert metadata["status"] == "running"
      assert metadata["ended_at"] == nil
    end
  end
end
