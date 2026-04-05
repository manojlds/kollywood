defmodule Kollywood.Chat.SessionTest do
  use ExUnit.Case, async: false

  alias Kollywood.Chat.Session

  @moduletag :capture_log

  setup do
    cwd =
      Path.join(System.tmp_dir!(), "kollywood-chat-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)

    on_exit(fn ->
      _ = File.rm_rf(cwd)
    end)

    %{cwd: cwd, project_slug: "chat-session-test"}
  end

  test "send_prompt queues message while ACP session initializes", %{cwd: cwd, project_slug: slug} do
    assert {:ok, pid} =
             Session.start_link(
               session_id: "chat-test-queued",
               project_slug: slug,
               cwd: cwd
             )

    assert {:ok, %{message_id: _id, queued: queued?}} =
             Session.send_prompt(pid, "hello while starting")

    assert is_boolean(queued?)

    assert {:ok, snapshot} = Session.snapshot(pid)

    assert Enum.any?(
             snapshot.messages,
             &(&1.role == "user" and &1.content == "hello while starting")
           )

    assert snapshot.status in [:starting, :running, :ready]
  end

  test "send_prompt returns readiness error when transport failed", %{project_slug: slug} do
    missing_cwd =
      Path.join(System.tmp_dir!(), "kollywood-chat-missing-#{System.unique_integer([:positive])}")

    assert {:ok, pid} =
             Session.start_link(
               session_id: "chat-test-error",
               project_slug: slug,
               cwd: missing_cwd
             )

    assert {:error, reason} = Session.send_prompt(pid, "hello")
    assert reason =~ "transport"
  end
end
