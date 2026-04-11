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

  test "session updates include tool and skill activity messages", %{cwd: cwd, project_slug: slug} do
    assert {:ok, pid} =
             Session.start_link(
               session_id: "chat-test-activity",
               project_slug: slug,
               cwd: cwd
             )

    fake_port = Port.open({:spawn, "cat"}, [:binary])

    on_exit(fn ->
      if Port.info(fake_port), do: Port.close(fake_port)
    end)

    :sys.replace_state(pid, fn state ->
      %{state | port: fake_port}
    end)

    tool_payload =
      Jason.encode!(%{
        "method" => "session/update",
        "params" => %{
          "update" => %{
            "sessionUpdate" => "tool_call",
            "subtype" => "started",
            "tool_call" => %{
              "shellToolCall" => %{"args" => %{"command" => "mix test"}}
            }
          }
        }
      })

    skill_payload =
      Jason.encode!(%{
        "method" => "session/update",
        "params" => %{
          "update" => %{
            "sessionUpdate" => "skill_completed",
            "skill" => "kollywood-prd",
            "text" => "Created 3 stories"
          }
        }
      })

    send(pid, {fake_port, {:data, tool_payload <> "\n"}})
    send(pid, {fake_port, {:data, skill_payload <> "\n"}})
    Process.sleep(25)

    assert {:ok, snapshot} = Session.snapshot(pid)

    assert Enum.any?(snapshot.messages, fn message ->
             message.role == "system" and
               String.contains?(message.content, "[tool started] shell")
           end)

    assert Enum.any?(snapshot.messages, fn message ->
             message.role == "system" and
               String.contains?(message.content, "[skill completed] kollywood-prd")
           end)
  end
end
