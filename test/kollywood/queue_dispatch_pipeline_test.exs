defmodule Kollywood.QueueDispatchPipelineTest do
  @moduledoc """
  Integration tests for the queue dispatch pipeline.

  Verifies that run_opts (especially log_files and on_event) survive
  the serialization round-trip through the RunQueue and that the
  WorkerConsumer reconstructs a working on_event callback.
  """

  use ExUnit.Case, async: false

  alias Kollywood.Repo
  alias Kollywood.RunQueue
  alias Kollywood.WorkerConsumer

  @tmp_dir System.tmp_dir!()

  defmodule FakeAgentPool do
    use DynamicSupervisor

    def start_link(opts) do
      name = Keyword.get(opts, :name, __MODULE__)
      DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
    end

    def start_run(server \\ __MODULE__, opts) do
      DynamicSupervisor.start_child(server, {Kollywood.RunWorker, opts})
    end

    def stop_run(server \\ __MODULE__, pid) do
      DynamicSupervisor.terminate_child(server, pid)
    end

    @impl true
    def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "log_files serialization round-trip" do
    test "log_files map survives JSON serialization and deserialization through the queue" do
      log_files = %{
        agent: "/tmp/test_run/agent.log",
        events: "/tmp/test_run/events.jsonl",
        worker: "/tmp/test_run/worker.log",
        reviewer: "/tmp/test_run/reviewer.log",
        run: "/tmp/test_run/run.log"
      }

      run_opts = [
        config: %Kollywood.Config{},
        attempt: 1,
        log_files: log_files,
        story_overrides_resolved: true
      ]

      serialized = serialize_run_opts_for_queue(run_opts)

      assert is_map(serialized)
      assert Map.has_key?(serialized, "log_files")

      log_files_serialized = serialized["log_files"]
      assert log_files_serialized["agent"] == "/tmp/test_run/agent.log"
      assert log_files_serialized["events"] == "/tmp/test_run/events.jsonl"

      json = Jason.encode!(serialized)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["log_files"]["agent"] == "/tmp/test_run/agent.log"
      assert decoded["log_files"]["events"] == "/tmp/test_run/events.jsonl"
    end

    test "log_files round-trips through RunQueue enqueue/claim" do
      log_files = %{
        agent: "/tmp/test_run/agent.log",
        events: "/tmp/test_run/events.jsonl",
        worker: "/tmp/test_run/worker.log"
      }

      run_opts = [
        config: %Kollywood.Config{},
        attempt: 1,
        log_files: log_files,
        story_overrides_resolved: true
      ]

      serialized = serialize_run_opts_for_queue(run_opts)

      {:ok, entry} =
        RunQueue.enqueue(%{
          issue_id: "test-logfiles-#{System.unique_integer([:positive])}",
          identifier: "US-RT-1",
          run_opts_snapshot: Jason.encode!(serialized),
          config_snapshot: Jason.encode!(%{"issue" => %{"id" => "test", "state" => "open"}})
        })

      fetched = RunQueue.get(entry.id)
      {:ok, decoded} = Jason.decode(fetched.run_opts_snapshot)

      assert decoded["log_files"]["agent"] == "/tmp/test_run/agent.log"
      assert decoded["log_files"]["events"] == "/tmp/test_run/events.jsonl"
    end
  end

  describe "on_event reconstruction in WorkerConsumer" do
    test "inject_on_event builds a callable on_event from log_files" do
      test_dir = Path.join(@tmp_dir, "kollywood_test_on_event_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)

      on_exit(fn -> File.rm_rf!(test_dir) end)

      events_path = Path.join(test_dir, "events.jsonl")
      File.write!(events_path, "")

      run_opts = [
        log_files: %{
          "events" => events_path,
          "agent" => Path.join(test_dir, "agent.log"),
          "worker" => Path.join(test_dir, "worker.log"),
          "run" => Path.join(test_dir, "run.log")
        },
        attempt: 3
      ]

      run_opts_with_event = WorkerConsumer.inject_on_event_for_test(run_opts, "TEST-001", 3)

      on_event = Keyword.fetch!(run_opts_with_event, :on_event)
      assert is_function(on_event, 1)

      on_event.(%{type: "turn_started", turn: 1, timestamp: DateTime.utc_now() |> DateTime.to_iso8601()})

      events_content = File.read!(events_path)
      assert String.contains?(events_content, "turn_started")
    end

    test "inject_on_event handles nil log_files gracefully" do
      run_opts = [attempt: 1]
      result = WorkerConsumer.inject_on_event_for_test(run_opts, "TEST-002", 1)

      on_event = Keyword.fetch!(result, :on_event)
      assert is_function(on_event, 1)

      assert on_event.(%{type: "test"}) == :ok
    end
  end

  describe "full queue dispatch pipeline" do
    test "worker consumer writes events to log files from queue entry" do
      test_dir = Path.join(@tmp_dir, "kollywood_test_pipeline_#{System.unique_integer([:positive])}")
      File.mkdir_p!(test_dir)

      on_exit(fn -> File.rm_rf!(test_dir) end)

      for f <- ~w(events.jsonl agent.log worker.log run.log reviewer.log) do
        File.write!(Path.join(test_dir, f), "")
      end

      log_files = %{
        "events" => Path.join(test_dir, "events.jsonl"),
        "agent" => Path.join(test_dir, "agent.log"),
        "worker" => Path.join(test_dir, "worker.log"),
        "run" => Path.join(test_dir, "run.log"),
        "reviewer" => Path.join(test_dir, "reviewer.log")
      }

      run_opts_snapshot =
        Jason.encode!(%{
          "attempt" => 1,
          "log_files" => log_files,
          "story_overrides_resolved" => true
        })

      issue_id = "test-pipeline-#{System.unique_integer([:positive])}"

      {:ok, _entry} =
        RunQueue.enqueue(%{
          issue_id: issue_id,
          identifier: "US-PIPE-1",
          run_opts_snapshot: run_opts_snapshot,
          config_snapshot:
            Jason.encode!(%{
              "issue" => %{"id" => issue_id, "identifier" => "US-PIPE-1", "title" => "Test", "state" => "open"}
            })
        })

      {:ok, pool} = FakeAgentPool.start_link(name: nil)

      {:ok, consumer} =
        WorkerConsumer.start_link(
          name: nil,
          agent_pool: pool,
          poll_interval_ms: 60_000,
          max_local_workers: 1
        )

      send(consumer, :poll)
      Process.sleep(1_000)

      events_content = File.read!(Path.join(test_dir, "events.jsonl"))

      assert String.length(events_content) > 0,
             "Expected events to be written to events.jsonl but file is empty. " <>
               "This means on_event was not reconstructed from log_files in the queue entry."
    end
  end

  # Expose the orchestrator's private serialization for testing
  defp serialize_run_opts_for_queue(run_opts) do
    run_opts
    |> Enum.reject(fn {key, _} -> key in [:workflow_store, :on_event] end)
    |> Enum.map(fn
      {key, value} when is_function(value) -> {Atom.to_string(key), nil}
      {key, value} -> {Atom.to_string(key), make_json_safe(value)}
    end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp make_json_safe(value) when is_struct(value) do
    value |> Map.from_struct() |> Map.drop([:__struct__]) |> make_json_safe()
  end

  defp make_json_safe(value) when is_map(value) do
    Map.new(value, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), make_json_safe(v)}
      {k, v} -> {to_string(k), make_json_safe(v)}
    end)
  end

  defp make_json_safe(value) when is_list(value), do: Enum.map(value, &make_json_safe/1)

  defp make_json_safe(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: Atom.to_string(value)

  defp make_json_safe(value) when is_pid(value), do: inspect(value)
  defp make_json_safe(value) when is_reference(value), do: inspect(value)
  defp make_json_safe(value) when is_function(value), do: nil
  defp make_json_safe(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp make_json_safe(value), do: value
end
