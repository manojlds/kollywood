defmodule Kollywood.AttemptDispatchPipelineTest do
  @moduledoc """
  Integration tests for the durable attempt dispatch pipeline.

  Verifies that run_opts (especially log_files and on_event) survive
  the serialization round-trip through RunAttempts and that the
  WorkerConsumer reconstructs a working on_event callback.
  """

  use ExUnit.Case, async: false

  alias Kollywood.Repo
  alias Kollywood.RunAttempts
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
      assert log_files_serialized["run"] == "/tmp/test_run/run.log"

      json = Jason.encode!(serialized)
      {:ok, decoded} = Jason.decode(json)

      assert decoded["log_files"]["agent"] == "/tmp/test_run/agent.log"
      assert decoded["log_files"]["run"] == "/tmp/test_run/run.log"
    end

    test "log_files round-trips through RunAttempts enqueue/lease" do
      log_files = %{
        agent: "/tmp/test_run/agent.log",
        worker: "/tmp/test_run/worker.log",
        run: "/tmp/test_run/run.log"
      }

      run_opts = [
        config: %Kollywood.Config{},
        attempt: 1,
        log_files: log_files,
        story_overrides_resolved: true
      ]

      serialized = serialize_run_opts_for_queue(run_opts)

      {:ok, entry} =
        RunAttempts.enqueue(%{
          issue_id: "test-logfiles-#{System.unique_integer([:positive])}",
          identifier: "US-RT-1",
          run_opts_snapshot: Jason.encode!(serialized),
          config_snapshot: Jason.encode!(%{"issue" => %{"id" => "test", "state" => "open"}})
        })

      fetched = RunAttempts.get_attempt(entry.id)
      {:ok, decoded} = Jason.decode(fetched.run_opts_snapshot)

      assert decoded["log_files"]["agent"] == "/tmp/test_run/agent.log"
      assert decoded["log_files"]["run"] == "/tmp/test_run/run.log"
    end
  end

  describe "on_event reconstruction in WorkerConsumer" do
    test "inject_on_event builds a callable on_event from log_files" do
      test_dir =
        Path.join(@tmp_dir, "kollywood_test_on_event_#{System.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)

      on_exit(fn -> File.rm_rf!(test_dir) end)

      run_path = Path.join(test_dir, "run.log")
      worker_path = Path.join(test_dir, "worker.log")
      File.write!(run_path, "")
      File.write!(worker_path, "")

      run_opts = [
        log_files: %{
          "agent" => Path.join(test_dir, "agent.log"),
          "worker" => worker_path,
          "run" => run_path
        },
        attempt: 3
      ]

      run_opts_with_event = WorkerConsumer.inject_on_event_for_test(run_opts, "TEST-001", 3)

      on_event = Keyword.fetch!(run_opts_with_event, :on_event)
      assert is_function(on_event, 1)

      on_event.(%{
        type: "turn_started",
        turn: 1,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      })

      run_content = File.read!(run_path)
      assert String.contains?(run_content, "turn_started")
    end

    test "inject_on_event handles nil log_files gracefully" do
      run_opts = [attempt: 1]
      result = WorkerConsumer.inject_on_event_for_test(run_opts, "TEST-002", 1)

      on_event = Keyword.fetch!(result, :on_event)
      assert is_function(on_event, 1)

      assert on_event.(%{type: "test"}) == :ok
    end
  end

  describe "log_files key atomization" do
    test "log_files string keys are converted to atoms for pattern matching in agent_runner" do
      run_opts_snapshot =
        Jason.encode!(%{
          "log_files" => %{
            "agent_stdout" => "/tmp/agent_stdout.log",
            "reviewer_stdout" => "/tmp/reviewer_stdout.log",
            "run" => "/tmp/run.log"
          },
          "attempt" => 1
        })

      {:ok, entry} =
        RunAttempts.enqueue(%{
          issue_id: "test-atomize-#{System.unique_integer([:positive])}",
          identifier: "US-ATOM-1",
          run_opts_snapshot: run_opts_snapshot,
          config_snapshot: Jason.encode!(%{"issue" => %{"id" => "test", "state" => "open"}})
        })

      fetched = RunAttempts.get_attempt(entry.id)
      {:ok, decoded_map} = Jason.decode(fetched.run_opts_snapshot)

      opts =
        Enum.reduce(decoded_map, [], fn {key, value}, acc ->
          if key in ~w(log_files attempt) do
            atom_key = String.to_existing_atom(key)
            resolved = WorkerConsumer.resolve_opt_value_for_test(atom_key, value)
            [{atom_key, resolved} | acc]
          else
            acc
          end
        end)

      log_files = Keyword.get(opts, :log_files)

      assert is_map(log_files)

      assert Map.has_key?(log_files, :agent_stdout),
             "Expected atom key :agent_stdout but got string keys: #{inspect(Map.keys(log_files))}"

      assert Map.has_key?(log_files, :reviewer_stdout)
      assert log_files[:agent_stdout] == "/tmp/agent_stdout.log"
    end
  end

  describe "full attempt dispatch pipeline" do
    test "worker consumer writes events to log files from attempt entry" do
      test_dir =
        Path.join(@tmp_dir, "kollywood_test_pipeline_#{System.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)

      on_exit(fn -> File.rm_rf!(test_dir) end)

      for f <- ~w(agent.log worker.log run.log reviewer.log) do
        File.write!(Path.join(test_dir, f), "")
      end

      log_files = %{
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
        RunAttempts.enqueue(%{
          issue_id: issue_id,
          identifier: "US-PIPE-1",
          run_opts_snapshot: run_opts_snapshot,
          config_snapshot:
            Jason.encode!(%{
              "issue" => %{
                "id" => issue_id,
                "identifier" => "US-PIPE-1",
                "title" => "Test",
                "state" => "open"
              }
            })
        })

      {:ok, pool} = FakeAgentPool.start_link(name: nil)

      {:ok, consumer} =
        WorkerConsumer.start_link(
          name: nil,
          agent_pool: pool,
          runner_fun: fn _issue, run_opts ->
            on_event = Keyword.get(run_opts, :on_event, fn _ -> :ok end)

            on_event.(%{
              type: "turn_started",
              turn: 1,
              timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
            })

            {:ok, %{"status" => "ok"}}
          end,
          poll_interval_ms: 60_000,
          max_local_workers: 1
        )

      send(consumer, :poll)
      Process.sleep(1_000)

      run_content = File.read!(Path.join(test_dir, "run.log"))

      assert String.length(run_content) > 0,
             "Expected run events to be written to run.log but file is empty. " <>
               "This means on_event was not reconstructed from log_files in the attempt entry."
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
