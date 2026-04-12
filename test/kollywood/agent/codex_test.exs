defmodule Kollywood.Agent.CodexTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.Codex
  alias Kollywood.Agent.Session

  setup do
    root =
      Path.join(System.tmp_dir!(), "kollywood_codex_test_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_codex.sh")

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

  test "uses argv prompt mode with no-approval headless default args", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} = Codex.start_session(workspace, %{command: cli_path})
    assert session.prompt_mode == :argv

    assert session.args == [
             "exec",
             "--ask-for-approval",
             "never",
             "--sandbox",
             "workspace-write"
           ]

    assert {:ok, result} = Codex.run_turn(session, "review this patch")

    assert result.output =~
             "args:exec --ask-for-approval never --sandbox workspace-write review this patch"

    assert result.output =~ "prompt:review this patch"
  end

  test "passes --model flag when model is configured in session", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} =
             Codex.start_session(workspace, %{command: cli_path, model: "gpt-5"})

    assert {:ok, result} = Codex.run_turn(session, "review this patch")
    assert result.output =~ "--model gpt-5"
  end

  test "prefers turn opts model over session model", %{workspace: workspace, cli_path: cli_path} do
    assert {:ok, %Session{} = session} =
             Codex.start_session(workspace, %{command: cli_path, model: "gpt-5"})

    assert {:ok, result} = Codex.run_turn(session, "review this patch", %{model: "o3"})
    assert result.output =~ "--model o3"
    refute result.output =~ "--model gpt-5"
  end
end
