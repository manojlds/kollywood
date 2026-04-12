defmodule Kollywood.Agent.CursorTest do
  use ExUnit.Case, async: true

  alias Kollywood.Agent.Cursor
  alias Kollywood.Agent.Session

  setup do
    root =
      Path.join(System.tmp_dir!(), "kollywood_cursor_test_#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    cli_path = Path.join(root, "fake_cursor.sh")
    raw_log_path = Path.join(root, "agent_stdout.log")
    first_chunk_marker = Path.join(root, "first_chunk.marker")

    File.mkdir_p!(workspace)

    File.write!(cli_path, """
    #!/usr/bin/env bash
    set -eu

    printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working"}]}}\\n'

    if [ -n "${CURSOR_FIRST_CHUNK_MARKER:-}" ]; then
      : > "$CURSOR_FIRST_CHUNK_MARKER"
    fi

    sleep "${CURSOR_STREAM_DELAY_SECS:-1}"

    printf '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"duration_api_ms":900,"result":"final output","session_id":"session-1"}\\n'
    """)

    File.chmod!(cli_path, 0o755)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{
      workspace: workspace,
      cli_path: cli_path,
      raw_log_path: raw_log_path,
      first_chunk_marker: first_chunk_marker
    }
  end

  test "streams incremental readable log output and preserves final parsed output", %{
    workspace: workspace,
    cli_path: cli_path,
    raw_log_path: raw_log_path,
    first_chunk_marker: first_chunk_marker
  } do
    assert {:ok, %Session{} = session} =
             Cursor.start_session(workspace, %{
               command: cli_path,
               env: %{
                 "CURSOR_FIRST_CHUNK_MARKER" => first_chunk_marker,
                 "CURSOR_STREAM_DELAY_SECS" => "1"
               }
             })

    turn_task =
      Task.async(fn ->
        Cursor.run_turn(session, "stream this turn", %{raw_log: raw_log_path})
      end)

    assert :ok = wait_for_file(first_chunk_marker, 2_000)
    assert Task.yield(turn_task, 50) == nil

    assert :ok = wait_for_file_contains(raw_log_path, "working", 2_000)

    raw_output_during_turn = File.read!(raw_log_path)
    assert raw_output_during_turn =~ "working"
    refute raw_output_during_turn =~ "\"type\":\"assistant\""
    refute raw_output_during_turn =~ "final output"

    assert {:ok, result} = Task.await(turn_task, 5_000)
    assert result.output == "final output"
    assert result.raw_output =~ "\"type\":\"assistant\""
    assert result.raw_output =~ "\"type\":\"result\""

    assert :ok = Cursor.stop_session(session)
  end

  test "passes --model flag when model is configured in session", %{
    workspace: workspace,
    cli_path: cli_path
  } do
    assert {:ok, %Session{} = session} =
             Cursor.start_session(workspace, %{command: cli_path, model: "gpt-5"})

    assert {:ok, result} = Cursor.run_turn(session, "hello")
    assert result.raw_output =~ "\"type\":\"assistant\""
  end

  test "inserts --model into command args", %{workspace: workspace} do
    session = %Session{
      id: 1,
      adapter: Cursor,
      workspace_path: workspace,
      command: "bash",
      args: [
        "-lc",
        "printf 'args:%s\\n' \"$*\"; printf '{\"type\":\"result\",\"result\":\"ok\"}\\n'",
        "--"
      ],
      env: %{},
      timeout_ms: 10_000,
      prompt_mode: :argv,
      model: "cursor-model"
    }

    assert {:ok, result} = Cursor.run_turn(session, "hello")
    assert result.raw_output =~ "args:--model cursor-model hello"
  end

  defp wait_for_file(path, timeout_ms) do
    wait_until(timeout_ms, fn -> File.exists?(path) end)
  end

  defp wait_for_file_contains(path, needle, timeout_ms) do
    wait_until(timeout_ms, fn ->
      case File.read(path) do
        {:ok, content} -> String.contains?(content, needle)
        {:error, _reason} -> false
      end
    end)
  end

  defp wait_until(timeout_ms, predicate) when is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_deadline(deadline, predicate)
  end

  defp wait_until_deadline(deadline, predicate) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(20)
        wait_until_deadline(deadline, predicate)
    end
  end
end
