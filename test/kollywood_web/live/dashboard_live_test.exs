defmodule KollywoodWeb.DashboardLiveTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Config
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects

  @test_stories [
    %{
      "id" => "US-001",
      "title" => "First Story",
      "status" => "open",
      "description" => "Description of first story",
      "acceptanceCriteria" => ["Must do X", "Must do Y"],
      "notes" => "Some notes here",
      "dependsOn" => [],
      "priority" => "high"
    },
    %{
      "id" => "US-002",
      "title" => "Second Story",
      "status" => "in_progress",
      "lastAttempt" => "20240101_120000",
      "lastError" => "Something went wrong"
    },
    %{
      "id" => "US-003",
      "title" => "Draft Story",
      "status" => "draft"
    }
  ]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "kollywood_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "prd.json"),
      Jason.encode!(%{"userStories" => @test_stories}, pretty: true)
    )

    {:ok, project} =
      Projects.create_project(%{
        name: "Dashboard Test Project #{System.unique_integer([:positive])}",
        provider: :local,
        repository: tmp_dir,
        local_path: tmp_dir
      })

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{project: project, tmp_dir: tmp_dir, tmp_root: tmp_dir}
  end

  describe "projects index" do
    test "renders project list", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Projects"
      assert html =~ project.name
    end
  end

  describe "dashboard overview" do
    test "renders counters and navigation", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ project.name
      assert html =~ "Overview"
      assert html =~ "Stories"
      assert html =~ "Runs"
      assert html =~ "Settings"
      assert html =~ "Open"
      assert html =~ "In Progress"
      assert html =~ "Done"
      assert html =~ "Failed"
    end

    test "navigates between tabs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}")

      view |> element("nav a", "Stories") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/stories")

      view |> element("nav a", "Runs") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/runs")

      view |> element("nav a", "Settings") |> render_click()
      assert_patch(view, ~p"/projects/#{project.slug}/settings")
    end

    test "shows not found for nonexistent project", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/projects/nonexistent")

      assert html =~ "Project not found"
    end
  end

  describe "dashboard routes" do
    test "renders overview page", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}")
      response = html_response(conn, 200)

      assert response =~ project.name
    end

    test "renders settings page", %{conn: conn, project: project} do
      conn = get(conn, ~p"/projects/#{project.slug}/settings")
      response = html_response(conn, 200)

      assert response =~ "Project Settings"
    end
  end

  describe "overview section" do
    test "shows recent activity for stories with lastAttempt", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "Recent Activity"
      assert html =~ "US-002"
      assert html =~ "Second Story"
    end

    test "recent activity rows link to run detail", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "/projects/#{project.slug}/runs/US-002"
    end
  end

  describe "settings section" do
    test "shows project settings and workflow editor", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/settings")

      assert html =~ "Project Settings"
      assert html =~ project.name
      assert html =~ "WORKFLOW.md"
    end

    test "shows workflow editor with frontmatter and body textareas when WORKFLOW.md exists", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "WORKFLOW.md"), """
      ---
      agent:
        kind: claude
      polling:
        interval_ms: 5000
      ---

      You are working on {{ issue.identifier }}.
      """)

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/settings")

      assert html =~ "Prompt Template"
      assert html =~ "Save Settings"
      assert html =~ "Save Template"
      assert html =~ "Review Prompt Template"
      assert html =~ "Save Review Template"
    end

    test "saves review template into WORKFLOW.md", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      File.write!(Path.join(tmp_dir, "WORKFLOW.md"), """
      ---
      review:
        enabled: true
        prompt_template: |
          old template content
      ---

      Body here.
      """)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/settings")

      view
      |> element("form[phx-submit='save_review_template']")
      |> render_submit(%{review_template: "new review template"})

      {:ok, content} = File.read(Path.join(tmp_dir, "WORKFLOW.md"))
      assert content =~ "new review template"
      refute content =~ "old template content"
    end
  end

  describe "stories section" do
    test "lists stories from tracker file", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "US-001"
      assert html =~ "First Story"
      assert html =~ "US-002"
      assert html =~ "Second Story"
    end

    test "shows status change dropdown for each story", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "update_story_status"
    end
  end

  describe "story detail page" do
    test "story links in stories list navigate to story detail route", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "/projects/#{project.slug}/stories/US-001"
    end

    test "story detail page renders story info and back link", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      assert html =~ "US-001"
      assert html =~ "Back to Stories"
    end

    test "story detail details tab shows story content", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      assert html =~ "First Story"
      assert html =~ "Description of first story"
      assert html =~ "Must do X"
      assert html =~ "Must do Y"
      assert html =~ "Some notes here"
      assert html =~ "high"
    end

    test "story detail page shows story not found for missing story", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/US-MISSING")

      assert html =~ "Story not found"
    end
  end

  describe "update_story_status event" do
    test "updates story status in tracker file on disk", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element(
        "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
      )
      |> render_click()

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))
      assert story["status"] == "done"
    end

    test "reflects updated status in the UI", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      html =
        view
        |> element(
          "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
        )
        |> render_click()

      assert html =~ "done"
    end
  end

  describe "draft stories" do
    test "draft stories appear in stories view under Draft section", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "US-003"
      assert html =~ "Draft Story"
      assert html =~ "Draft"
    end

    test "draft stories are excluded from overview stat counters", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      refute html =~ "US-003"
    end

    test "draft stories have dashed border styling", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "border-dashed"
    end

    test "draft stories can be promoted to open via status dropdown", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element(
        "button[phx-click='update_story_status'][phx-value-id='US-003'][phx-value-status='open']"
      )
      |> render_click()

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-003"))
      assert story["status"] == "open"
    end
  end

  describe "reset_story event" do
    test "reset button appears for non-open stories", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "phx-click=\"reset_story\""
    end

    test "resets story to open and clears lastAttempt/lastError in tracker file", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
      |> render_click()

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-002"))
      assert story["status"] == "open"
      assert story["lastAttempt"] == nil
      assert story["lastError"] == nil
    end
  end

  describe "run detail section" do
    test "run detail route redirects to story detail with runs tab", %{
      conn: conn,
      project: project
    } do
      {:error, {:live_redirect, %{to: redirected_to}}} =
        live(conn, ~p"/projects/#{project.slug}/runs/US-002")

      assert redirected_to == ~p"/projects/#{project.slug}/stories/US-002?tab=runs"
    end

    test "redirected story detail page shows runs tab content", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/US-002?tab=runs")

      assert html =~ "No runs yet for this story."
    end

    test "runs list shows view link for stories with lastAttempt", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "View"
      assert html =~ "/projects/#{project.slug}/runs/US-002"
    end
  end

  describe "story detail runs tab" do
    test "shows no logs message when story has no run logs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-MISSING")

      html =
        view
        |> element("button[phx-click='set_story_tab'][phx-value-tab='runs']")
        |> render_click()

      assert html =~ "No runs yet for this story."
    end

    test "shows log tab bar when run logs exist", %{
      conn: conn,
      project: project,
      tmp_root: tmp_root
    } do
      story_id = "US-TAB-TEST"
      context = prepare_run_logs!(tmp_root, story_id)
      File.write!(context.files.agent, "agent output here")

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Agent"
      assert html =~ "Checks"
      assert html =~ "Reviewer"
      assert html =~ "Runtime"
    end

    test "agent tab shows agent.log content by default in runs tab", %{
      conn: conn,
      project: project,
      tmp_root: tmp_root
    } do
      story_id = "US-AGENT-TAB"
      context = prepare_run_logs!(tmp_root, story_id)
      File.write!(context.files.agent, "agent log content")

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "agent log content"
    end

    test "log tab switching changes displayed log content", %{
      conn: conn,
      project: project,
      tmp_root: tmp_root
    } do
      story_id = "US-SWITCH-TAB"
      context = prepare_run_logs!(tmp_root, story_id)
      File.write!(context.files.agent, "agent content")
      File.write!(context.files.worker, "worker log content")

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      html =
        view
        |> element("button[phx-click='set_log_tab'][phx-value-tab='worker']")
        |> render_click()

      assert html =~ "worker log content"
    end

    test "shows no output placeholder when active log file is empty", %{
      conn: conn,
      project: project,
      tmp_root: tmp_root
    } do
      story_id = "US-EMPTY-LOG"
      _context = prepare_run_logs!(tmp_root, story_id)

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "No output yet."
    end

    test "poll_logs handle_info updates log content", %{
      conn: conn,
      project: project,
      tmp_root: tmp_root
    } do
      story_id = "US-POLL-TEST"
      context = prepare_run_logs!(tmp_root, story_id, status: "running")

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      File.write!(context.files.agent, "new content after poll")

      send(view.pid, :poll_logs)

      html = render(view)
      assert html =~ "new content after poll"
    end
  end

  defp prepare_run_logs!(root, story_id, opts \\ []) do
    config = %Config{
      workspace: %{root: root},
      tracker: %{path: nil}
    }

    issue = %{id: story_id, identifier: story_id, title: "Test #{story_id}"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    status = Keyword.get(opts, :status, "finished")
    RunLogs.complete_attempt(context, %{status: status, turn_count: 1})

    context
  end
end
