defmodule Kollywood.Runtime.HostTest do
  @moduledoc """
  Integration tests for `Kollywood.Runtime.Host`.

  These tests launch real devenv processes (a lightweight python HTTP server)
  to verify that the runtime properly starts, healthchecks, and stops processes
  with per-issue port isolation.
  """
  use ExUnit.Case, async: false

  alias Kollywood.Runtime

  @moduletag :runtime_integration
  @moduletag timeout: 120_000

  @devenv_nix ~S"""
  { pkgs, ... }:
  {
    packages = [ pkgs.python3 ];

    processes.test_server = {
      exec = ''
        exec ${pkgs.python3}/bin/python3 -u -c "
  import http.server, os, signal, sys
  signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
  port = int(os.environ.get('TEST_HTTP_PORT', '48500'))
  s = http.server.HTTPServer(('127.0.0.1', port), http.server.BaseHTTPRequestHandler)
  print(f'test_server listening on {port}', flush=True)
  s.serve_forever()
  "
      '';
    };
  }
  """

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_runtime_host_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "devenv.nix"), @devenv_nix)

    on_exit(fn ->
      System.cmd("devenv", ["processes", "down"],
        cd: root,
        stderr_to_stdout: true
      )

      File.rm_rf!(root)
    end)

    %{workspace_path: root}
  end

  describe "start/stop lifecycle" do
    test "start launches process, healthcheck confirms port, stop tears it down", %{
      workspace_path: ws
    } do
      port = 48501

      config = %{
        runtime: %{
          processes: ["test_server"],
          env: %{},
          ports: %{"TEST_HTTP_PORT" => port},
          port_offset_mod: 1,
          start_timeout_ms: 45_000,
          stop_timeout_ms: 15_000
        }
      }

      state = Runtime.init(:host, config, %{path: ws, key: "lifecycle-happy"})

      assert {:ok, started} = Runtime.start(state)
      assert started.started? == true
      assert started.process_state == :running
      assert is_port(started.manager_port)

      assert :ok = Runtime.healthcheck(started)
      assert_port_open(port)

      assert {:ok, stopped} = Runtime.stop(started)
      assert stopped.started? == false
      assert stopped.process_state == :stopped

      Process.sleep(1_000)
      assert_port_closed(port)
    end

    test "start is idempotent — second call is a no-op", %{workspace_path: ws} do
      port = 48502
      state = init_runtime(ws, "idempotent", port)

      assert {:ok, started} = Runtime.start(state)
      original_port = started.manager_port

      assert {:ok, started2} = Runtime.start(started)
      assert started2.started? == true
      assert started2.manager_port == original_port

      assert {:ok, _stopped} = Runtime.stop(started2)
    end

    test "stop on a never-started runtime is a no-op", %{workspace_path: ws} do
      state = init_runtime(ws, "stop-noop", 48503)

      assert state.started? == false
      assert {:ok, stopped} = Runtime.stop(state)
      assert stopped.started? == false
    end
  end

  describe "port isolation" do
    test "two concurrent runtimes in separate workspaces get different port offsets", %{
      workspace_path: ws
    } do
      ws_a = Path.join(ws, "issue-A")
      ws_b = Path.join(ws, "issue-B")

      for dir <- [ws_a, ws_b] do
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "devenv.nix"), @devenv_nix)
      end

      config = runtime_config([], %{"TEST_HTTP_PORT" => 48600}, 100)
      test_pid = self()

      task1 =
        Task.async(fn ->
          state = Runtime.init(:host, config, %{path: ws_a, key: "issue-A"})
          {:ok, started} = Runtime.start(state)
          send(test_pid, {:started, :a, started.port_offset, started.resolved_ports})
          wait_for_signal(:done)
          Runtime.stop(started)
        end)

      task2 =
        Task.async(fn ->
          state = Runtime.init(:host, config, %{path: ws_b, key: "issue-B"})
          {:ok, started} = Runtime.start(state)
          send(test_pid, {:started, :b, started.port_offset, started.resolved_ports})
          wait_for_signal(:done)
          Runtime.stop(started)
        end)

      assert_receive {:started, _, offset_a, ports_a}, 10_000
      assert_receive {:started, _, offset_b, ports_b}, 10_000

      assert offset_a != offset_b
      assert ports_a["TEST_HTTP_PORT"] != ports_b["TEST_HTTP_PORT"]

      send(task1.pid, :done)
      send(task2.pid, :done)
      Task.await(task1, 15_000)
      Task.await(task2, 15_000)
    end

    test "release frees the offset lease so it can be reacquired", %{workspace_path: ws} do
      config = runtime_config([], %{}, 1)
      test_pid = self()

      # Acquire lease in process A
      pid_a =
        spawn_link(fn ->
          state = Runtime.init(:host, config, %{path: ws, key: "release-lease"})
          {:ok, started} = Runtime.start(state)
          send(test_pid, {:acquired, started.offset_lease_name, started.port_offset})

          wait_for_signal(:release_and_exit)
          Runtime.release(started)
          Runtime.stop(started)
          send(test_pid, :released)
        end)

      assert_receive {:acquired, lease_name, _offset}, 10_000
      assert lease_name != nil

      # Tell A to release, then wait for confirmation
      send(pid_a, :release_and_exit)
      assert_receive :released, 10_000

      # Process B should now be able to acquire the same slot
      _pid_b =
        spawn_link(fn ->
          state = Runtime.init(:host, config, %{path: ws, key: "release-lease"})
          {:ok, started} = Runtime.start(state)
          send(test_pid, {:reacquired, started.offset_lease_name})
          Runtime.release(started)
          Runtime.stop(started)
        end)

      assert_receive {:reacquired, lease_name_b}, 10_000
      assert lease_name_b != nil
    end
  end

  describe "healthcheck" do
    test "healthcheck fails when port is not reachable within timeout", %{workspace_path: ws} do
      config = %{
        runtime: %{
          processes: [],
          env: %{},
          ports: %{"GHOST_PORT" => 48700},
          port_offset_mod: 1,
          start_timeout_ms: 1_000,
          stop_timeout_ms: 5_000
        }
      }

      state = Runtime.init(:host, config, %{path: ws, key: "healthcheck-timeout"})
      assert {:error, msg} = Runtime.healthcheck(state)
      assert msg =~ "ports not reachable"
      assert msg =~ "GHOST_PORT"
    end

    test "healthcheck is skipped when KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK is set", %{
      workspace_path: ws
    } do
      config = %{
        runtime: %{
          processes: [],
          env: %{"KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK" => "1"},
          ports: %{"GHOST_PORT" => 48701},
          port_offset_mod: 1,
          start_timeout_ms: 1_000,
          stop_timeout_ms: 5_000
        }
      }

      state = Runtime.init(:host, config, %{path: ws, key: "healthcheck-skip"})
      assert :ok = Runtime.healthcheck(state)
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp init_runtime(workspace_path, key, base_port) do
    config = runtime_config(["test_server"], %{"TEST_HTTP_PORT" => base_port}, 1)
    workspace = %{path: workspace_path, key: key}
    Runtime.init(:host, config, workspace)
  end

  defp runtime_config(processes, ports, port_offset_mod) do
    %{
      runtime: %{
        processes: processes,
        env: %{"KOLLYWOOD_RUNTIME_SKIP_HEALTHCHECK" => "1"},
        ports: ports,
        port_offset_mod: port_offset_mod,
        start_timeout_ms: 45_000,
        stop_timeout_ms: 15_000
      }
    }
  end

  defp wait_for_signal(signal) do
    receive do
      ^signal -> :ok
    after
      15_000 -> raise "timeout waiting for #{inspect(signal)}"
    end
  end

  defp assert_port_open(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 3_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        flunk("Expected port #{port} to be open, but got: #{inspect(reason)}")
    end
  end

  defp assert_port_closed(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        flunk("Expected port #{port} to be closed, but it's still open")

      {:error, _reason} ->
        :ok
    end
  end
end
