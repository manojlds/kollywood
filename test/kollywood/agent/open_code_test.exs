defmodule Kollywood.Agent.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.OpenCode
  alias Kollywood.Agent.Session

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_opencode_test_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_opencode.sh")

    File.mkdir_p!(workspace)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"
    echo "args:$*"
    echo "prompt:$prompt"
    """)

    File.chmod!(cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{workspace: workspace, cli_path: cli_path}
  end

  test "runs a turn using stdin prompt mode", %{workspace: workspace, cli_path: cli_path} do
    assert {:ok, %Session{} = session} = OpenCode.start_session(workspace, %{command: cli_path})
    assert session.prompt_mode == :stdin

    assert {:ok, result} = OpenCode.run_turn(session, "ship feature")
    assert result.output =~ "prompt:ship feature"
  end
end
