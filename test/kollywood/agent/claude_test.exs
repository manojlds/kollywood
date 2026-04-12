defmodule Kollywood.Agent.ClaudeTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.Claude
  alias Kollywood.Agent.Session

  setup do
    root =
      Path.join(System.tmp_dir!(), "kollywood_claude_test_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_claude.sh")

    File.mkdir_p!(workspace)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="${@: -1}"
    echo "args:$*"
    echo "prompt:$prompt"
    """)

    File.chmod!(cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{workspace: workspace, cli_path: cli_path}
  end

  test "uses argv prompt mode with headless default args", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} = Claude.start_session(workspace, %{command: cli_path})
    assert session.prompt_mode == :argv
    assert session.args == ["--print", "--dangerously-skip-permissions"]

    assert {:ok, result} = Claude.run_turn(session, "review this patch")
    assert result.output =~ "args:--print --dangerously-skip-permissions review this patch"
    assert result.output =~ "prompt:review this patch"
  end

  test "passes --model flag when model is configured in session", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} =
             Claude.start_session(workspace, %{command: cli_path, model: "claude-sonnet-4-6"})

    assert session.model == "claude-sonnet-4-6"

    assert {:ok, result} = Claude.run_turn(session, "hello")
    assert result.output =~ "--model claude-sonnet-4-6"
  end

  test "passes --model flag with claude-opus-4 model", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} =
             Claude.start_session(workspace, %{command: cli_path, model: "claude-opus-4"})

    assert session.model == "claude-opus-4"

    assert {:ok, result} = Claude.run_turn(session, "hello")
    assert result.output =~ "--model claude-opus-4"
  end

  test "does not pass --model flag when model is not configured", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} = Claude.start_session(workspace, %{command: cli_path})
    assert session.model == nil

    assert {:ok, result} = Claude.run_turn(session, "hello")
    refute result.output =~ "--model"
  end

  test "prefers turn opts model over session model", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} =
             Claude.start_session(workspace, %{command: cli_path, model: "claude-sonnet-4-6"})

    assert {:ok, result} = Claude.run_turn(session, "hello", %{model: "claude-opus-4"})
    assert result.output =~ "--model claude-opus-4"
    refute result.output =~ "--model claude-sonnet-4-6"
  end
end
