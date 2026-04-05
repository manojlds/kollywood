defmodule KollywoodWeb.ChatLiveTest do
  use KollywoodWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Kollywood.Projects

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "kollywood_chat_live_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    slug = "chat-live-#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(%{
        name: "Chat Live #{System.unique_integer([:positive])}",
        slug: slug,
        provider: :local,
        repository: root
      })

    on_exit(fn ->
      _ = File.rm_rf(root)
    end)

    %{project: project}
  end

  test "renders chat page and allows creating a new chat session", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.slug}/chat")

    assert html =~ "Project Chat"
    assert has_element?(view, "button[phx-click='new_chat']")

    view
    |> element("button[phx-click='new_chat']")
    |> render_click()

    refute render(view) =~ "No chats yet."
  end

  test "chat status guidance and queue label render for starting state", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/chat")

    assert html =~ "Start a new chat and ask the agent"
    assert html =~ "Send"
  end
end
