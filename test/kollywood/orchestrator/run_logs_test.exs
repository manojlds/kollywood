defmodule Kollywood.Orchestrator.RunLogsTest do
  use ExUnit.Case, async: true

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_run_logs_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    config = %Config{
      workspace: %{root: root},
      tracker: %{path: nil}
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
end
