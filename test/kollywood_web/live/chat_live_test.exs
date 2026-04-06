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
    workflow_path = Projects.workflow_path(project)
    File.mkdir_p!(Path.dirname(workflow_path))

    File.write!(
      workflow_path,
      """
      ---
      workspace:
        strategy: clone
      agent:
        kind: opencode
      ---

      Work on {{ issue.identifier }}.
      """
    )

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

    assert html =~ "Click Onboard Project to start onboarding chat."
    assert html =~ "Send"
  end

  test "sessions panel is available as a separate tab", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/chat")

    assert has_element?(view, "button[phx-click='set_panel'][phx-value-panel='chat']")
    assert has_element?(view, "button[phx-click='set_panel'][phx-value-panel='sessions']")

    html =
      view
      |> element(".tabs button[phx-click='set_panel'][phx-value-panel='sessions']")
      |> render_click()

    assert html =~ "Sessions"
    refute html =~ "Sessions ("
    assert html =~ "No chat sessions yet"
  end

  test "non-onboarded project shows chat-only tabs and onboarding CTA", %{
    conn: conn,
    project: project
  } do
    workflow_path = Projects.workflow_path(project)
    tracker_path = Projects.tracker_path(project)

    if is_binary(workflow_path), do: File.rm(workflow_path)

    if is_binary(tracker_path) do
      File.mkdir_p!(Path.dirname(tracker_path))
      File.write!(tracker_path, ~s({"project":"demo","userStories":[]}))
    end

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/chat")

    assert html =~ "Chat"
    assert html =~ "Set up this project for Kollywood"
    assert html =~ "Onboard Project"
    refute html =~ "Stories"
    refute html =~ "Runs"
    refute html =~ "Settings"
    refute html =~ "This project is not fully onboarded yet"
  end

  test "non-onboarded project disables new chat and requires onboarding button", %{
    conn: conn,
    project: project
  } do
    workflow_path = Projects.workflow_path(project)
    if is_binary(workflow_path), do: File.rm(workflow_path)

    {:ok, view, html} = live(conn, ~p"/projects/#{project.slug}/chat")

    assert has_element?(view, "button[phx-click='new_chat'][disabled]")
    assert has_element?(view, ".tabs button[phx-click='set_panel'][phx-value-panel='sessions']")
    assert html =~ "Click Onboard Project to start onboarding chat."

    assert render(view) =~ "Click Onboard Project to start onboarding chat."
  end
end
