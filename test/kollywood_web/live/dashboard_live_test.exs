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
      "description" => "## First Story Details\n\nThis is **formatted** description text.",
      "acceptanceCriteria" => ["Must do X", "Must do Y"],
      "notes" => "Remember to run `mix test` before closing this story.",
      "dependsOn" => [],
      "priority" => "high"
    },
    %{
      "id" => "US-002",
      "title" => "Second Story",
      "status" => "in_progress",
      "lastRunAttempt" => 1,
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

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(tmp_dir, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

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

    on_exit(fn ->
      case previous_home do
        nil -> System.delete_env("KOLLYWOOD_HOME")
        value -> System.put_env("KOLLYWOOD_HOME", value)
      end

      File.rm_rf!(tmp_dir)
    end)

    %{project: project, tmp_dir: tmp_dir}
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
    test "shows no recent activity when no runs exist", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "Recent Activity"
      assert html =~ "No recent activity"
    end

    test "shows completed run attempt in recent activity", %{
      conn: conn,
      project: project
    } do
      prepare_run_logs!(project.slug, "US-001")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "US-001"
      assert html =~ "/projects/#{project.slug}/runs/US-001/1"
    end

    test "recent activity shows story title when available", %{
      conn: conn,
      project: project
    } do
      prepare_run_logs!(project.slug, "US-001")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "First Story"
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
      tmp_dir: _tmp_dir
    } do
      write_workflow!(project, """
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
      tmp_dir: _tmp_dir
    } do
      write_workflow!(project, """
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

      {:ok, content} = File.read(project.workflow_path)
      assert content =~ "new review template"
      refute content =~ "old template content"
    end

    test "save settings writes publish.mode instead of legacy auto_push fields", %{
      conn: conn,
      project: project,
      tmp_dir: _tmp_dir
    } do
      write_workflow!(project, """
      ---
      agent:
        kind: claude
        max_turns: 1
      workspace:
        strategy: clone
      publish:
        auto_push: on_pass
        auto_create_pr: ready
      git:
        base_branch: main
      ---

      Body here.
      """)

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/settings")

      view
      |> element("form[phx-submit='save_settings']")
      |> render_submit(%{
        settings: %{
          agent: %{"kind" => "claude", "max_turns" => "2", "command" => ""},
          workspace: %{"strategy" => "clone"},
          checks: %{"required" => "", "timeout_ms" => "10000"},
          review: %{
            "enabled" => "false",
            "max_cycles" => "1",
            "pass_token" => "REVIEW_PASS",
            "fail_token" => "REVIEW_FAIL",
            "agent_custom" => "false",
            "agent" => %{}
          },
          publish: %{"provider" => "", "mode" => "auto_merge", "pr_type" => "ready"},
          git: %{"base_branch" => "main"}
        }
      })

      {:ok, content} = File.read(project.workflow_path)
      assert content =~ "mode: auto_merge"
      refute content =~ "auto_push:"
      refute content =~ "auto_create_pr:"
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
      assert html =~ "<h2>First Story Details</h2>"
      assert html =~ "<strong>formatted</strong>"
      assert html =~ "Must do X"
      assert html =~ "Must do Y"
      assert html =~ "<code>mix test</code>"
      refute html =~ "## First Story Details"
      refute html =~ "`mix test`"
      assert html =~ "high"
    end

    test "story detail page shows story not found for missing story", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/US-MISSING")

      assert html =~ "Story not found"
    end

    test "shows actions menu with manual status transitions", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")
      html = render(view)

      assert has_element?(view, "button[phx-click='open_edit_story_form'][phx-value-id='US-001']")
      assert has_element?(view, "button[phx-click='delete_story'][phx-value-id='US-001']")
      assert html =~ "Delete US-001? This cannot be undone."

      assert has_element?(
               view,
               "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
             )

      refute has_element?(
               view,
               "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='in_progress']"
             )
    end

    test "resets story from detail page and updates status badge", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-002")
      assert render(view) =~ "Reset US-002? This will clear run data and remove the worktree."

      html =
        view
        |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
        |> render_click()

      assert html =~ "Open"

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-002"))
      assert story["status"] == "open"
    end

    test "deletes story from detail page and shows not found state", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-003")

      html =
        view
        |> element("button[phx-click='delete_story'][phx-value-id='US-003']")
        |> render_click()

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

      assert html =~ "Done"
    end

    test "does not expose manual transition to in_progress", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      refute has_element?(
               view,
               "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='in_progress']"
             )
    end
  end

  describe "story editor" do
    test "adds a new story from UI", %{conn: conn, project: project, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='open_new_story_form']")
      |> render_click()

      view
      |> element("#story-editor-form")
      |> render_submit(%{
        story: %{
          id: "US-100",
          title: "Story From UI",
          description: "New story description",
          acceptanceCriteria: "Criterion A\nCriterion B",
          priority: "4",
          status: "draft",
          dependsOn: "US-001",
          notes: "UI note"
        }
      })

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-100"))

      assert story["title"] == "Story From UI"
      assert story["status"] == "draft"
      assert story["dependsOn"] == ["US-001"]
    end

    test "edits an existing story from UI", %{conn: conn, project: project, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='open_edit_story_form'][phx-value-id='US-001']")
      |> render_click()

      view
      |> element("#story-editor-form")
      |> render_submit(%{
        story: %{
          id: "US-001",
          title: "Updated Story Title",
          description: "Updated description",
          acceptanceCriteria: "Updated criterion",
          priority: "7",
          status: "done",
          dependsOn: "",
          notes: "Updated notes"
        }
      })

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))

      assert story["title"] == "Updated Story Title"
      assert story["status"] == "done"
      assert story["priority"] == 7
    end

    test "deletes a story from UI", %{conn: conn, project: project, tmp_dir: tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='delete_story'][phx-value-id='US-003']")
      |> render_click()

      {:ok, content} = File.read(Path.join(tmp_dir, "prd.json"))
      {:ok, data} = Jason.decode(content)

      refute Enum.any?(data["userStories"], &(&1["id"] == "US-003"))
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

    test "resets story to open and clears run-attempt metadata in tracker file", %{
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
      assert story["lastRunAttempt"] == nil
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

    test "run detail back link points to story runs tab", %{
      conn: conn,
      project: project
    } do
      story_id = "US-BACK-LINK"
      prepare_run_logs!(project.slug, story_id)

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "/projects/#{project.slug}/stories/#{story_id}?tab=runs"
    end

    test "runs list shows view link for stories with tracker run metadata", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "View"
      assert html =~ "/projects/#{project.slug}/runs/US-002"
    end
  end

  describe "stories section actions" do
    test "story cards do not show inline Runs links", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      refute html =~ "/projects/#{project.slug}/stories/US-001?tab=runs"
      refute html =~ "/projects/#{project.slug}/stories/US-002?tab=runs"
    end

    test "story cards use compact actions menu with reset action", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "hero-ellipsis-horizontal"
      assert html =~ "Reset Story"
    end

    test "runs page uses latest run logs over stale tracker last-run metadata", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      stories = [
        %{
          "id" => "US-LATEST",
          "title" => "Latest Attempt Story",
          "status" => "done",
          "lastRunAttempt" => 1
        }
      ]

      File.write!(
        Path.join(tmp_dir, "prd.json"),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      _ = prepare_run_logs!(project.slug, "US-LATEST")
      _ = prepare_run_logs!(project.slug, "US-LATEST")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "/projects/#{project.slug}/runs/US-LATEST/2"
      assert html =~ "/projects/#{project.slug}/runs/US-LATEST/1"
    end

    test "runs page shows run logs even when tracker lacks lastRunAttempt", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      stories = [
        %{
          "id" => "US-NO-LAST",
          "title" => "No Last Attempt",
          "status" => "done"
        }
      ]

      File.write!(
        Path.join(tmp_dir, "prd.json"),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      _ = prepare_run_logs!(project.slug, "US-NO-LAST")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "/projects/#{project.slug}/runs/US-NO-LAST/1"
      assert html =~ "#1"
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
      project: project
    } do
      story_id = "US-TAB-TEST"
      context = prepare_run_logs!(project.slug, story_id)
      File.write!(context.files.agent_stdout, "agent output here")

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Agent"
      assert html =~ "Review Agent"
      assert html =~ "Worker"
    end

    test "agent tab shows agent_stdout.log content by default in runs tab", %{
      conn: conn,
      project: project
    } do
      story_id = "US-AGENT-TAB"
      context = prepare_run_logs!(project.slug, story_id)
      File.write!(context.files.agent_stdout, "agent log content")

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "agent log content"
    end

    test "log tab switching changes displayed log content", %{
      conn: conn,
      project: project
    } do
      story_id = "US-SWITCH-TAB"
      context = prepare_run_logs!(project.slug, story_id)
      File.write!(context.files.agent_stdout, "agent content")
      File.write!(context.files.run, "worker log content")

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      html =
        view
        |> element("button[phx-click='set_log_tab'][phx-value-tab='worker']")
        |> render_click()

      assert html =~ "worker log content"
    end

    test "renders ANSI colors and intensity across agent/review/worker tabs", %{
      conn: conn,
      project: project
    } do
      story_id = "US-ANSI-TABS"
      context = prepare_run_logs!(project.slug, story_id)

      File.write!(context.files.agent_stdout, "start\n\e[31magent error\e[0m\n")
      File.write!(context.files.reviewer_stdout, "\e[1;33mreview warning\e[0m")
      File.write!(context.files.run, "\e[30;42mworker ok\e[0m")

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "<span style=\"color: #dc2626\">agent error</span>"

      review_html =
        view
        |> element("button[phx-click='set_log_tab'][phx-value-tab='review_agent']")
        |> render_click()

      assert review_html =~
               "<span style=\"color: #ca8a04; font-weight: 700\">review warning</span>"

      worker_html =
        view
        |> element("button[phx-click='set_log_tab'][phx-value-tab='worker']")
        |> render_click()

      assert worker_html =~
               "<span style=\"color: #111827; background-color: #16a34a\">worker ok</span>"
    end

    test "escapes log HTML and strips malformed ANSI control characters", %{
      conn: conn,
      project: project
    } do
      story_id = "US-ANSI-SAFE"
      context = prepare_run_logs!(project.slug, story_id)

      File.write!(
        context.files.agent_stdout,
        "<script>alert('x')</script>\n\e[31mboom\e[0m\nmalformed:\e[33oops"
      )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"
      refute html =~ "<script>alert('x')</script>"
      assert html =~ "<span style=\"color: #dc2626\">boom</span>"
      assert html =~ "malformed:33oops"
      refute html =~ "\e"
    end

    test "shows no output placeholder when active log file is empty", %{
      conn: conn,
      project: project
    } do
      story_id = "US-EMPTY-LOG"
      _context = prepare_run_logs!(project.slug, story_id)

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "No output yet."
    end

    test "poll_logs handle_info updates log content", %{
      conn: conn,
      project: project
    } do
      story_id = "US-POLL-TEST"
      context = prepare_run_logs!(project.slug, story_id, status: "running")

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      File.write!(context.files.agent_stdout, "new content after poll")

      send(view.pid, :poll_logs)

      html = render(view)
      assert html =~ "new content after poll"
    end
  end

  describe "story sort order" do
    test "done stories are ordered most-recent-first by completedAt", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      stories = [
        %{
          "id" => "US-OLD",
          "title" => "Older Done",
          "status" => "done",
          "completedAt" => "20240101_120000"
        },
        %{
          "id" => "US-NEW",
          "title" => "Newer Done",
          "status" => "done",
          "completedAt" => "20240201_120000"
        }
      ]

      File.write!(
        Path.join(tmp_dir, "prd.json"),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      newer_pos = :binary.match(html, "US-NEW") |> elem(0)
      older_pos = :binary.match(html, "US-OLD") |> elem(0)
      assert newer_pos < older_pos
    end

    test "in_progress stories appear before open stories in rendered HTML", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      stories = [
        %{"id" => "US-OPEN", "title" => "Open Story", "status" => "open"},
        %{
          "id" => "US-IP",
          "title" => "In Progress Story",
          "status" => "in_progress",
          "startedAt" => "20240101_120000"
        }
      ]

      File.write!(
        Path.join(tmp_dir, "prd.json"),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      ip_pos = :binary.match(html, "US-IP") |> elem(0)
      open_pos = :binary.match(html, "US-OPEN") |> elem(0)
      assert ip_pos < open_pos
    end
  end

  defp prepare_run_logs!(project_slug, story_id, opts \\ []) do
    config = %Config{
      workspace: %{root: Path.join(System.tmp_dir!(), "kollywood_dashboard_workspaces")},
      tracker: %{path: nil, project_slug: project_slug}
    }

    issue = %{id: story_id, identifier: story_id, title: "Test #{story_id}"}
    {:ok, context} = RunLogs.prepare_attempt(config, issue, nil)

    status = Keyword.get(opts, :status, "finished")
    RunLogs.complete_attempt(context, %{status: status, turn_count: 1})

    context
  end

  defp write_workflow!(project, content) do
    File.mkdir_p!(Path.dirname(project.workflow_path))
    File.write!(project.workflow_path, content)
  end
end
