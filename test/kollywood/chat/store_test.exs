defmodule Kollywood.Chat.StoreTest do
  use ExUnit.Case, async: false

  alias Kollywood.Chat

  setup do
    project_slug = "chat-store-#{System.unique_integer([:positive])}"

    cwd =
      Path.join(System.tmp_dir!(), "kollywood-chat-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(cwd)

    on_exit(fn ->
      Chat.list_sessions(project_slug)
      |> Enum.each(fn session ->
        _ = Chat.delete_session(session.id)
      end)

      _ = File.rm_rf(cwd)
    end)

    %{project_slug: project_slug, cwd: cwd}
  end

  test "creates multiple sessions for one project", %{project_slug: project_slug, cwd: cwd} do
    assert {:ok, first} = Chat.create_session(project_slug, cwd)
    assert {:ok, second} = Chat.create_session(project_slug, cwd)

    sessions = Chat.list_sessions(project_slug)
    ids = Enum.map(sessions, & &1.id)

    assert first.id in ids
    assert second.id in ids
    assert length(ids) == 2
  end

  test "snapshot returns session metadata and messages", %{project_slug: project_slug, cwd: cwd} do
    assert {:ok, session} = Chat.create_session(project_slug, cwd)
    assert {:ok, snapshot} = Chat.get_snapshot(session.id)

    assert snapshot.id == session.id
    assert snapshot.project_slug == project_slug
    assert snapshot.cwd == cwd
    assert is_list(snapshot.messages)
  end

  test "rejects missing cwd", %{project_slug: project_slug} do
    missing =
      Path.join(System.tmp_dir!(), "kollywood-chat-missing-#{System.unique_integer([:positive])}")

    assert {:error, reason} = Chat.create_session(project_slug, missing)
    assert reason =~ "cwd"
  end
end
