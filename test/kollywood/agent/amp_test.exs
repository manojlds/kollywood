defmodule Kollywood.Agent.AmpTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.Amp
  alias Kollywood.Agent.Session

  setup do
    root =
      Path.join(System.tmp_dir!(), "kollywood_amp_test_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_amp.sh")

    File.mkdir_p!(workspace)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    prompt="$(cat)"

    if [ "$prompt" = "fail" ]; then
      echo "amp failed"
      exit 23
    fi

    echo "args:$*"
    echo "cwd:$PWD"
    echo "prompt:$prompt"
    """)

    File.chmod!(cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{workspace: workspace, cli_path: cli_path}
  end

  test "runs a turn using stdin prompt mode", %{workspace: workspace, cli_path: cli_path} do
    assert {:ok, %Session{} = session} = Amp.start_session(workspace, %{command: cli_path})
    assert session.prompt_mode == :stdin

    assert {:ok, result} = Amp.run_turn(session, "hello amp")
    assert result.output =~ "cwd:#{workspace}"
    assert result.output =~ "prompt:hello amp"
    assert result.exit_code == 0
  end

  test "returns error on non-zero exit code", %{workspace: workspace, cli_path: cli_path} do
    assert {:ok, session} = Amp.start_session(workspace, %{command: cli_path})

    assert {:error, reason} = Amp.run_turn(session, "fail")
    assert reason =~ "exit code 23"
    assert reason =~ "amp failed"
  end
end
