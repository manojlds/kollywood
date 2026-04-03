defmodule Kollywood.Runtime.DockerTest do
  @moduledoc """
  Tests for `Kollywood.Runtime.Docker`.

  Unit tests for init/config work without Docker. Integration tests
  (tagged :docker_integration) require a running Docker daemon and the
  kollywood-runtime image built from priv/docker/runtime/Dockerfile.
  """
  use ExUnit.Case, async: false

  alias Kollywood.Runtime

  @moduletag timeout: 120_000

  describe "init (no Docker needed)" do
    test "init sets kind to :docker" do
      config = docker_config()
      state = Runtime.init(:docker, config, %{path: "/tmp/test-ws", key: "docker-init"})

      assert state.kind == :docker
      assert state.image == "kollywood-runtime:latest"
      assert state.started? == false
      assert state.container_id == nil
    end

    test "init respects custom image from config" do
      config = docker_config(image: "my-custom-image:v2")
      state = Runtime.init(:docker, config, %{path: "/tmp/test-ws", key: "docker-custom-image"})

      assert state.image == "my-custom-image:v2"
    end

    test "init resolves ports and env" do
      config = docker_config(ports: %{"HTTP_PORT" => 4000}, port_offset_mod: 1)
      state = Runtime.init(:docker, config, %{path: "/tmp/test-ws", key: "docker-ports"})

      assert Map.has_key?(state.resolved_ports, "HTTP_PORT")
      assert is_integer(state.resolved_ports["HTTP_PORT"])
      assert state.resolved_ports["HTTP_PORT"] >= 4000
      assert Map.has_key?(state.env, "HTTP_PORT")
    end

    test "init with nil workspace returns base state" do
      config = docker_config()
      state = Runtime.init(:docker, config, nil)

      assert state.kind == :docker
      assert state.workspace_path == nil
    end
  end

  describe "config integration" do
    test "Config parses runtime.kind: docker with image" do
      yaml = """
      ---
      agent:
        kind: claude
      workspace:
        strategy: worktree
      runtime:
        kind: docker
        image: my-image:latest
        processes:
          - web
        ports:
          HTTP_PORT: 3000
      ---
      Prompt template here.
      """

      assert {:ok, config, _prompt} = Kollywood.Config.parse(yaml)
      assert config.runtime.kind == :docker
      assert config.runtime.image == "my-image:latest"
      assert config.runtime.processes == ["web"]
      assert config.runtime.ports == %{"HTTP_PORT" => 3000}
    end

    test "Config defaults image to nil when not specified" do
      yaml = """
      ---
      agent:
        kind: claude
      workspace:
        strategy: worktree
      runtime:
        kind: docker
        processes:
          - web
      ---
      Prompt.
      """

      assert {:ok, config, _prompt} = Kollywood.Config.parse(yaml)
      assert config.runtime.kind == :docker
      assert config.runtime.image == nil
    end
  end

  describe "lifecycle (requires Docker)" do
    @describetag :docker_integration

    setup do
      skip_unless_docker!()

      root =
        Path.join(
          System.tmp_dir!(),
          "kollywood_runtime_docker_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      File.write!(Path.join(root, "pitchfork.toml"), pitchfork_toml())

      on_exit(fn ->
        System.cmd("docker", ["rm", "-f", "kollywood-rt-docker-lifecycle"],
          stderr_to_stdout: true
        )

        File.rm_rf!(root)
      end)

      %{workspace_path: root}
    end

    test "full lifecycle: create, start, healthcheck, stop", %{workspace_path: ws} do
      port = 48800

      config =
        docker_config(
          processes: ["test_server"],
          ports: %{"TEST_HTTP_PORT" => port},
          port_offset_mod: 1
        )

      state = Runtime.init(:docker, config, %{path: ws, key: "docker-lifecycle"})

      assert {:ok, started} = Runtime.start(state)
      assert started.started? == true
      assert started.container_id != nil

      assert :ok = Runtime.healthcheck(started)

      assert {:ok, stopped} = Runtime.stop(started)
      assert stopped.started? == false
      assert stopped.container_id == nil
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp docker_config(opts \\ []) do
    %{
      runtime: %{
        kind: :docker,
        processes: Keyword.get(opts, :processes, []),
        env: Keyword.get(opts, :env, %{}),
        ports: Keyword.get(opts, :ports, %{}),
        port_offset_mod: Keyword.get(opts, :port_offset_mod, 1000),
        start_timeout_ms: 45_000,
        stop_timeout_ms: 15_000,
        image: Keyword.get(opts, :image, nil)
      }
    }
  end

  defp skip_unless_docker! do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> ExUnit.Assertions.flunk("Docker daemon not available — skipping")
    end
  rescue
    _ -> ExUnit.Assertions.flunk("Docker not installed — skipping")
  end

  defp pitchfork_toml do
    ~S"""
    [daemons.test_server]
    run = "perl -MIO::Socket::INET -e '$p=$ENV{TEST_HTTP_PORT}||48800; $s=IO::Socket::INET->new(LocalAddr=>\"127.0.0.1\",LocalPort=>$p,Proto=>\"tcp\",Listen=>5,Reuse=>1) or die $!; while($c=$s->accept){ close $c; }'"
    """
  end
end
