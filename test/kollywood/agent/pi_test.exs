defmodule Kollywood.Agent.PiTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.Pi
  alias Kollywood.Agent.Session

  setup do
    root = Path.join(System.tmp_dir!(), "kollywood_pi_test_#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_pi.sh")

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
    assert {:ok, %Session{} = session} = Pi.start_session(workspace, %{command: cli_path})
    assert session.prompt_mode == :stdin

    assert {:ok, result} = Pi.run_turn(session, "ship pi adapter")
    assert result.output =~ "prompt:ship pi adapter"
  end
end
