defmodule Kollywood.Orchestrator.RunLogsTest do
  use ExUnit.Case, async: false

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
    end

    test "includes agent path in metadata files map", %{context: context} do
      metadata = File.read!(context.files.metadata) |> Jason.decode!()
      assert Map.has_key?(metadata["files"], "agent")
      assert metadata["files"]["agent"] == context.files.agent
    end

    test "includes agent in tracker_metadata", %{context: context} do
      tracker_meta = RunLogs.tracker_metadata(context)
      assert Map.has_key?(tracker_meta.run_logs.files, :agent)
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

  describe "append_event/2 with other events" do
    test "does not write to agent.log for non-agent events", %{context: context} do
      RunLogs.append_event(context, %{type: :run_started})
      RunLogs.append_event(context, %{type: :workspace_ready})
      RunLogs.append_event(context, %{type: :check_passed, output: "check output"})

      content = File.read!(context.files.agent)
      assert content == ""
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
end
