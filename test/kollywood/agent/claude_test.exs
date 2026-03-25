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
end
