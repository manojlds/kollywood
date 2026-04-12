defmodule Kollywood.AgentTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent
  alias Kollywood.Agent.Session
  alias Kollywood.Config

  defmodule SpyAdapter do
    @behaviour Kollywood.Agent

    @impl true
    def start_session(_workspace, _opts), do: {:error, "not implemented"}

    @impl true
    def run_turn(session, _prompt, opts) do
      send(self(), {:spy_run_turn, session, opts})

      {:ok,
       %{output: "ok", raw_output: "ok", exit_code: 0, duration_ms: 1, command: "spy", args: []}}
    end

    @impl true
    def stop_session(_session), do: :ok
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "kollywood_agent_test_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_cli.sh")

    File.mkdir_p!(workspace)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"
    echo "args:$*"
    echo "pwd:$PWD"
    echo "prompt:$prompt"
    echo "token:${KOLLYWOOD_TOKEN:-missing}"
    """)

    File.chmod!(cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{workspace: workspace, cli_path: cli_path}
  end

  test "maps agent kind to adapter module" do
    assert Agent.adapter_module(:claude) == Kollywood.Agent.Claude
    assert Agent.adapter_module(:codex) == Kollywood.Agent.Codex
    assert Agent.adapter_module(:cursor) == Kollywood.Agent.Cursor
    assert Agent.adapter_module(:opencode) == Kollywood.Agent.OpenCode
    assert Agent.adapter_module(:pi) == Kollywood.Agent.Pi
  end

  test "dispatches start/run/stop using config agent kind", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    config = %Config{
      tracker: %{},
      polling: %{},
      workspace: %{},
      hooks: %{},
      raw: %{},
      agent: %{
        kind: :pi,
        command: cli_path,
        model: "gpt-5",
        env: %{"KOLLYWOOD_TOKEN" => "abc123"},
        timeout_ms: 10_000,
        args: []
      }
    }

    assert {:ok, %Session{} = session} = Agent.start_session(config, workspace)
    assert session.adapter == Kollywood.Agent.Pi
    assert session.model == "gpt-5"

    assert {:ok, result} = Agent.run_turn(session, "finish stage 3")
    assert result.output =~ "pwd:#{workspace}"
    assert result.output =~ "prompt:finish stage 3"
    assert result.output =~ "token:abc123"

    assert :ok = Agent.stop_session(session)
  end

  test "passes session model to adapter run_turn options" do
    session = %Session{
      id: 1,
      adapter: SpyAdapter,
      workspace_path: "/tmp",
      command: "spy",
      model: "claude-sonnet-4",
      args: [],
      env: %{},
      timeout_ms: 1_000,
      prompt_mode: :argv
    }

    assert {:ok, _result} = Agent.run_turn(session, "hi", %{})

    assert_receive {:spy_run_turn, ^session, opts}
    assert opts[:model] == "claude-sonnet-4"
  end

  test "keeps adapter default args when config args is empty", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    config = %Config{
      tracker: %{},
      polling: %{},
      workspace: %{},
      hooks: %{},
      raw: %{},
      agent: %{
        kind: :pi,
        command: cli_path,
        env: %{},
        timeout_ms: 10_000,
        args: []
      }
    }

    assert {:ok, %Session{} = session} = Agent.start_session(config, workspace)
    assert session.adapter == Kollywood.Agent.Pi
    assert session.args == ["--print"]

    assert {:ok, result} = Agent.run_turn(session, "quick check")
    assert result.output =~ "args:--print"
    assert result.output =~ "prompt:quick check"
    assert :ok = Agent.stop_session(session)
  end

  test "cursor adapter uses non-interactive default args", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    config = %Config{
      tracker: %{},
      polling: %{},
      workspace: %{},
      hooks: %{},
      raw: %{},
      agent: %{
        kind: :cursor,
        command: cli_path,
        env: %{},
        timeout_ms: 10_000,
        args: []
      }
    }

    assert {:ok, %Session{} = session} = Agent.start_session(config, workspace)
    assert session.adapter == Kollywood.Agent.Cursor

    assert session.args == [
             "agent",
             "--print",
             "--output-format",
             "stream-json",
             "--stream-partial-output",
             "--force",
             "--trust"
           ]

    assert :ok = Agent.stop_session(session)
  end

  test "codex adapter uses non-interactive no-approval default args", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    config = %Config{
      tracker: %{},
      polling: %{},
      workspace: %{},
      hooks: %{},
      raw: %{},
      agent: %{
        kind: :codex,
        command: cli_path,
        env: %{},
        timeout_ms: 10_000,
        args: []
      }
    }

    assert {:ok, %Session{} = session} = Agent.start_session(config, workspace)
    assert session.adapter == Kollywood.Agent.Codex

    assert session.args == [
             "exec",
             "--ask-for-approval",
             "never",
             "--sandbox",
             "workspace-write"
           ]

    assert :ok = Agent.stop_session(session)
  end
end
