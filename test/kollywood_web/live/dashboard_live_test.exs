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
    },
    %{
      "id" => "US-004",
      "title" => "Pending Merge Story",
      "status" => "pending_merge"
    }
  ]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "kollywood_test_#{System.unique_integer([:positive])}")

    previous_home = System.get_env("KOLLYWOOD_HOME")
    kollywood_home = Path.join(tmp_dir, ".kollywood-home")
    System.put_env("KOLLYWOOD_HOME", kollywood_home)

    File.mkdir_p!(tmp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Dashboard Test Project #{System.unique_integer([:positive])}",
        provider: :local,
        repository: tmp_dir
      })

    tracker_path = Projects.tracker_path(project)
    File.mkdir_p!(Path.dirname(tracker_path))
    File.write!(tracker_path, Jason.encode!(%{"userStories" => @test_stories}, pretty: true))

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
      assert html =~ "Pending Merge"
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

    test "recent activity avoids duplicating terminal phase labels", %{
      conn: conn,
      project: project
    } do
      prepare_run_logs!(project.slug, "US-RECENT-FAIL", status: "failed")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}")

      assert html =~ "US-RECENT-FAIL"
      refute html =~ "Run failed"
    end
  end

  describe "settings section" do
    test "shows project settings and workflow editor", %{conn: conn, project: project} do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/settings")

      assert html =~ "Project Settings"
      assert html =~ project.name
      assert html =~ "Repository"
      assert html =~ project.repository
      refute html =~ "Local Path"
      refute html =~ Projects.local_path(project)
      assert html =~ "WORKFLOW.md"
      assert html =~ "value=\"cursor\""
      assert html =~ "When enabled, checks stop at the first failure."

      assert html =~
               ~r/When disabled,\s+all\s+configured checks run\s+so every failure is reported in one cycle\./
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
      quality:
        max_cycles: 1
        checks:
          required: []
        review:
          enabled: false
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
      quality:
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

      {:ok, content} = File.read(Projects.workflow_path(project))
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
          agent: %{
            "kind" => "claude",
            "max_turns" => "2",
            "max_concurrent_agents" => "3",
            "retries_enabled" => "true",
            "command" => ""
          },
          workspace: %{"strategy" => "clone"},
          quality: %{
            "max_cycles" => "1",
            "checks" => %{
              "required" => "",
              "timeout_ms" => "10000",
              "fail_fast" => "true",
              "max_cycles" => "1"
            },
            "review" => %{
              "enabled" => "false",
              "max_cycles" => "1",
              "agent_custom" => "false",
              "agent" => %{}
            }
          },
          publish: %{"provider" => "", "mode" => "auto_merge", "pr_type" => "ready"},
          git: %{"base_branch" => "main"}
        }
      })

      {:ok, content} = File.read(Projects.workflow_path(project))
      assert content =~ "mode: auto_merge"
      assert content =~ "max_concurrent_agents: 3"
      assert content =~ "retries_enabled: true"
      refute content =~ "pass_token:"
      refute content =~ "fail_token:"
      refute content =~ "auto_push:"
      refute content =~ "auto_create_pr:"
    end

    test "save settings persists checks.fail_fast toggle", %{
      conn: conn,
      project: project,
      tmp_dir: _tmp_dir
    } do
      write_workflow!(project, """
      ---
      agent:
        kind: cursor
      workspace:
        strategy: clone
      quality:
        checks:
          required:
            - mix test
          timeout_ms: 10000
          fail_fast: true
          max_cycles: 1
      publish:
        mode: push
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
          agent: %{
            "kind" => "cursor",
            "max_turns" => "1",
            "max_concurrent_agents" => "1",
            "retries_enabled" => "false",
            "command" => ""
          },
          workspace: %{"strategy" => "clone"},
          quality: %{
            "max_cycles" => "1",
            "checks" => %{
              "required" => "mix test",
              "timeout_ms" => "10000",
              "fail_fast" => "false",
              "max_cycles" => "1"
            },
            "review" => %{
              "enabled" => "false",
              "max_cycles" => "1",
              "agent_custom" => "false",
              "agent" => %{}
            },
            "testing" => %{
              "enabled" => "false",
              "max_cycles" => "1",
              "timeout_ms" => "10000",
              "agent_custom" => "false",
              "agent" => %{}
            }
          },
          publish: %{"provider" => "", "mode" => "push", "pr_type" => "ready"},
          git: %{"base_branch" => "main"}
        }
      })

      {:ok, config, _prompt} = Projects.workflow_path(project) |> File.read!() |> Config.parse()
      assert config.checks.fail_fast == false
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

    test "renders kanban by default with grouped status columns", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert has_element?(view, "#stories-view-toggle")
      assert has_element?(view, "#stories-kanban-view")
      refute has_element?(view, "#stories-list-view")

      assert has_element?(view, "#stories-column-open #story-card-US-001")
      assert has_element?(view, "#stories-column-in_progress #story-card-US-002")
      assert has_element?(view, "#stories-column-draft #story-card-US-003")
      assert has_element?(view, "#stories-column-pending_merge #story-card-US-004")

      assert has_element?(
               view,
               "#stories-column-pending_merge header .badge.badge-sm.badge-ghost",
               "1"
             )

      html = render(view)

      draft_pos = :binary.match(html, ~s(id="stories-column-draft")) |> elem(0)
      open_pos = :binary.match(html, ~s(id="stories-column-open")) |> elem(0)
      ip_pos = :binary.match(html, ~s(id="stories-column-in_progress")) |> elem(0)
      done_pos = :binary.match(html, ~s(id="stories-column-done")) |> elem(0)
      pending_merge_pos = :binary.match(html, ~s(id="stories-column-pending_merge")) |> elem(0)
      merged_pos = :binary.match(html, ~s(id="stories-column-merged")) |> elem(0)
      failed_pos = :binary.match(html, ~s(id="stories-column-failed")) |> elem(0)

      assert draft_pos < open_pos
      assert open_pos < ip_pos
      assert ip_pos < done_pos
      assert done_pos < pending_merge_pos
      assert pending_merge_pos < merged_pos
      assert merged_pos < failed_pos

      assert html =~ "flex min-w-full items-start gap-3"
      assert html =~ "min-w-[18rem] basis-[18rem] grow shrink-0 overflow-hidden"
      refute html =~ "min-w-72 w-0 flex-1 overflow-hidden"
      refute html =~ "grid-flow-col auto-cols-[minmax(17.5rem,_1fr)]"
      refute Regex.match?(~r/restoreViewPreference\(\)\s*this\.persistCurrentView\(\)/, html)
    end

    test "switches between kanban and list views", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='set_stories_view'][phx-value-view='list']")
      |> render_click()

      assert_patch(view, ~p"/projects/#{project.slug}/stories?#{[view: "list"]}")
      assert has_element?(view, "#stories-list-view")
      refute has_element?(view, "#stories-kanban-view")

      view
      |> element("button[phx-click='set_stories_view'][phx-value-view='kanban']")
      |> render_click()

      assert_patch(view, ~p"/projects/#{project.slug}/stories")
      assert has_element?(view, "#stories-kanban-view")
      refute has_element?(view, "#stories-list-view")
    end

    test "respects stories view query parameter", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories?#{[view: "list"]}")

      assert has_element?(view, "#stories-list-view")
      refute has_element?(view, "#stories-kanban-view")
    end

    test "keeps list view while navigating between project tabs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories?#{[view: "list"]}")

      view
      |> element("a[href='/projects/#{project.slug}/runs?view=list']")
      |> render_click()

      assert_patch(view, ~p"/projects/#{project.slug}/runs?#{[view: "list"]}")

      html = render(view)
      assert html =~ ~s(href="/projects/#{project.slug}/stories?view=list")
    end

    test "list view groups stories by state order with collapsible sections", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='set_stories_view'][phx-value-view='list']")
      |> render_click()

      assert has_element?(view, "#stories-list-group-draft")
      assert has_element?(view, "#stories-list-group-open")
      assert has_element?(view, "#stories-list-group-in_progress")
      assert has_element?(view, "#stories-list-group-pending_merge")
      assert has_element?(view, "#stories-list-group-content-draft")
      assert has_element?(view, "#stories-list-group-content-pending_merge #story-card-US-004")

      assert has_element?(
               view,
               "#stories-list-group-pending_merge .badge.badge-sm.badge-ghost",
               "1"
             )

      html = render(view)
      draft_pos = :binary.match(html, ~s(id="stories-list-group-draft")) |> elem(0)
      open_pos = :binary.match(html, ~s(id="stories-list-group-open")) |> elem(0)
      ip_pos = :binary.match(html, ~s(id="stories-list-group-in_progress")) |> elem(0)

      pending_merge_pos =
        :binary.match(html, ~s(id="stories-list-group-pending_merge")) |> elem(0)

      assert draft_pos < open_pos
      assert open_pos < ip_pos
      assert ip_pos < pending_merge_pos

      view
      |> element("#stories-list-group-toggle-draft")
      |> render_click()

      refute has_element?(view, "#stories-list-group-content-draft")

      view
      |> element("#stories-list-group-toggle-draft")
      |> render_click()

      assert has_element?(view, "#stories-list-group-content-draft")
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

    test "story detail back link keeps list view query", %{conn: conn, project: project} do
      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/US-001?#{[view: "list"]}")

      assert html =~ ~s(href="/projects/#{project.slug}/stories?view=list")
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
      assert html =~ "whitespace-nowrap"
      assert html =~ "flex items-start justify-between"

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
      tmp_dir: _tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-002")

      html =
        view
        |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
        |> render_click()

      assert html =~ "Confirm action"
      assert html =~ "Stop work on US-002?"

      html =
        view
        |> element("button[data-confirm-action='reset_story'][phx-value-id='US-002']")
        |> render_click()

      assert html =~ "Draft"

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-002"))
      assert story["status"] == "draft"
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
      tmp_dir: _tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element(
        "button[phx-click='update_story_status'][phx-value-id='US-001'][phx-value-status='done']"
      )
      |> render_click()

      {:ok, content} = File.read(Projects.tracker_path(project))
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

  describe "kanban drag and drop" do
    test "moves a story to a valid status and persists to tracker", %{
      conn: conn,
      project: project,
      tmp_dir: _tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      _html =
        view
        |> element("#stories-kanban-view")
        |> render_hook("move_story_card", %{
          "id" => "US-001",
          "from_status" => "open",
          "to_status" => "done"
        })

      assert has_element?(view, "#stories-column-done #story-card-US-001")
      refute has_element?(view, "#stories-column-open #story-card-US-001")

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))
      assert story["status"] == "done"
    end

    test "rejects invalid manual transition drop with clear feedback", %{
      conn: conn,
      project: project,
      tmp_dir: _tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      _html =
        view
        |> element("#stories-kanban-view")
        |> render_hook("move_story_card", %{
          "id" => "US-001",
          "from_status" => "open",
          "to_status" => "in_progress"
        })

      assert has_element?(view, "#stories-column-open #story-card-US-001")
      refute has_element?(view, "#stories-column-in_progress #story-card-US-001")

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))
      assert story["status"] == "open"
    end

    test "renders touch drag handles and kanban drop metadata", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert has_element?(view, "#stories-kanban-view[phx-hook='.KanbanBoardDnD']")
      assert has_element?(view, "#stories-dnd-feedback[data-dnd-feedback]")
      assert has_element?(view, "#stories-column-done[data-story-drop-target='true']")
      assert has_element?(view, "#story-card-US-001[data-story-card='true']")

      assert has_element?(
               view,
               "#story-card-US-001[data-story-manual-targets='draft,done,failed,cancelled']"
             )

      assert has_element?(view, "#story-card-US-001 button[data-story-touch-handle='true']")
    end
  end

  describe "story editor" do
    test "adds a new story from UI", %{conn: conn, project: project, tmp_dir: _tmp_dir} do
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
          notes: "UI note",
          testingNotes: "Tester-only guidance",
          execution_agent_kind: "cursor",
          execution_review_agent_kind: "claude",
          execution_review_max_cycles: "3",
          execution_testing_enabled: "true",
          execution_testing_agent_kind: "opencode",
          execution_testing_max_cycles: "4"
        }
      })

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-100"))

      assert story["title"] == "Story From UI"
      assert story["status"] == "draft"
      assert story["dependsOn"] == ["US-001"]
      assert story["settings"]["execution"]["agent_kind"] == "cursor"
      assert story["settings"]["execution"]["review_agent_kind"] == "claude"
      assert story["settings"]["execution"]["review_max_cycles"] == 3
      assert story["settings"]["execution"]["testing_enabled"] == true
      assert story["settings"]["execution"]["testing_agent_kind"] == "opencode"
      assert story["settings"]["execution"]["testing_max_cycles"] == 4
      assert story["testingNotes"] == "Tester-only guidance"
    end

    test "edits an existing story from UI", %{conn: conn, project: project, tmp_dir: _tmp_dir} do
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
          notes: "Updated notes",
          testingNotes: "Updated tester note"
        }
      })

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))

      assert story["title"] == "Updated Story Title"
      assert story["status"] == "done"
      assert story["priority"] == 7
      assert story["testingNotes"] == "Updated tester note"
    end

    test "deletes a story from UI", %{conn: conn, project: project, tmp_dir: _tmp_dir} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element("button[phx-click='delete_story'][phx-value-id='US-003']")
      |> render_click()

      {:ok, content} = File.read(Projects.tracker_path(project))
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
      tmp_dir: _tmp_dir
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      view
      |> element(
        "button[phx-click='update_story_status'][phx-value-id='US-003'][phx-value-status='open']"
      )
      |> render_click()

      {:ok, content} = File.read(Projects.tracker_path(project))
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

    test "resets story to draft and clears run-attempt metadata in tracker file", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories")

      html =
        view
        |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
        |> render_click()

      assert html =~ "Confirm action"
      assert html =~ "Stop work on US-002?"

      view
      |> element("button[data-confirm-action='reset_story'][phx-value-id='US-002']")
      |> render_click()

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-002"))
      assert story["status"] == "draft"
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

    test "pending merge story shows preview panel above tabs when preview is enabled", %{
      conn: conn,
      project: project
    } do
      story_id = "US-PREVIEW-TOP"

      write_workflow!(project, """
      ---
      preview:
        enabled: true
      ---

      body
      """)

      append_story!(project, %{
        "id" => story_id,
        "title" => "Preview Top Placement",
        "status" => "pending_merge"
      })

      {:ok, view, html} = live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}")

      title_pos = html |> :binary.match("Preview Top Placement") |> elem(0)
      panel_pos = html |> :binary.match("Preview Environment") |> elem(0)
      tabs_pos = html |> :binary.match("phx-value-tab=\"details\"") |> elem(0)

      assert title_pos < panel_pos
      assert panel_pos < tabs_pos
      assert html =~ "Start Preview"
      assert html =~ "Merge Without Preview"

      html =
        view
        |> element("button[phx-click='start_preview'][phx-value-story_id='#{story_id}']")
        |> render_click()

      assert html =~ "Preview Environment"
      assert html =~ "Starting preview runtime..."
      assert html =~ "Starting Preview"

      now = DateTime.utc_now()

      send(
        view.pid,
        {:preview_start_finished, project.slug, story_id,
         {:ok,
          %{
            status: :running,
            preview_url: "http://localhost:4912",
            resolved_ports: %{"PORT" => 4912},
            expires_at: DateTime.add(now, 3600, :second),
            runtime_kind: :host,
            runtime_state: %{},
            started_at: now,
            workspace_path: "/tmp/preview-panel-test",
            last_error: nil
          }}}
      )

      Process.sleep(10)
      html = render(view)

      assert html =~ "Preview running"
      assert html =~ "URL: http://localhost:4912"
      assert html =~ "PORT=4912"
    end

    test "pending merge actions use in-app confirmation modal", %{conn: conn, project: project} do
      story_id = "US-PREVIEW-MERGE-CONFIRM"

      write_workflow!(project, """
      ---
      preview:
        enabled: true
      ---

      body
      """)

      append_story!(project, %{
        "id" => story_id,
        "title" => "Preview merge confirm",
        "status" => "pending_merge"
      })

      {:ok, view, html} = live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}")

      refute html =~ "onclick=\"return confirm('Merge"

      html =
        view
        |> element(
          "button[phx-click='merge_story'][phx-value-story_id='#{story_id}'][phx-value-mode='without_preview']"
        )
        |> render_click()

      assert html =~ "Confirm action"
      assert html =~ "Merge #{story_id} without starting a preview?"

      assert has_element?(
               view,
               "button[data-confirm-action='merge_story'][phx-value-story_id='#{story_id}'][phx-value-mode='without_preview']"
             )
    end

    test "story detail load shows already-running preview session", %{
      conn: conn,
      project: project
    } do
      story_id = "US-PREVIEW-RELOAD"

      write_workflow!(project, """
      ---
      preview:
        enabled: true
      ---

      body
      """)

      append_story!(project, %{
        "id" => story_id,
        "title" => "Preview reload",
        "status" => "pending_merge"
      })

      assert {:ok, _session} =
               Kollywood.PreviewSessionManager.handoff_runtime(
                 project.slug,
                 story_id,
                 %{
                   module: Kollywood.Runtime.Host,
                   kind: :host,
                   workspace_path: Path.join(System.tmp_dir!(), "preview-reload-test"),
                   resolved_ports: %{"PORT" => 4950}
                 },
                 []
               )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}")

      assert html =~ "Preview running"
      assert html =~ "URL: http://localhost:4950"
      assert html =~ "PORT=4950"
    end

    test "pending merge preview panel keeps start preview for non-local projects and hides local merge",
         %{
           conn: conn,
           tmp_dir: tmp_dir
         } do
      {:ok, remote_project} =
        Projects.create_project(%{
          name: "Remote Preview #{System.unique_integer([:positive])}",
          provider: :github,
          repository: Path.join(tmp_dir, "remote-preview-repo")
        })

      tracker_path = Projects.tracker_path(remote_project)
      File.mkdir_p!(Path.dirname(tracker_path))

      File.write!(
        tracker_path,
        Jason.encode!(%{
          "userStories" => [
            %{
              "id" => "US-REMOTE-PREVIEW",
              "title" => "Remote pending merge",
              "status" => "pending_merge",
              "settings" => %{"execution" => %{"preview_enabled" => true}}
            }
          ]
        })
      )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{remote_project.slug}/stories/US-REMOTE-PREVIEW")

      assert html =~ "Preview Environment"
      assert html =~ "Start Preview"
      assert html =~ "PR/MR platform"
      refute html =~ "Merge Without Preview"
      refute html =~ "Approve &amp; Merge"
    end

    test "run detail shows where to access preview controls after pending merge handoff", %{
      conn: conn,
      project: project
    } do
      story_id = "US-PREVIEW-HANDOFF"

      prepare_run_logs!(project.slug, story_id,
        events: [
          %{type: :publish_pending_merge, branch: "preview/us-preview-handoff"}
        ],
        status: "ok"
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Preview controls are on the story Details tab"
      assert html =~ "Open Story Details"
      assert html =~ "/projects/#{project.slug}/stories/#{story_id}"
    end

    test "runs list shows view link for stories with tracker run metadata", %{
      conn: conn,
      project: project
    } do
      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "View"
      assert html =~ "/projects/#{project.slug}/runs/US-002"
    end

    test "run detail shows snapshot-backed settings with workflow drift warning", %{
      conn: conn,
      project: project
    } do
      story_id = "US-SNAPSHOT"

      write_workflow!(project, """
      ---
      agent:
        kind: claude
      workspace:
        strategy: clone
      ---

      Body
      """)

      _ =
        prepare_run_logs!(project.slug, story_id,
          metadata_overrides: %{"settings_snapshot" => settings_snapshot_fixture()},
          events: [
            %{type: :turn_started, turn: 1},
            %{type: :turn_succeeded, turn: 1, output: "ok"}
          ]
        )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Back to Runs"
      assert html =~ "Agent Turn 1"
      refute html =~ "set_run_detail_panel_tab"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Snapshot story",
        "status" => "done"
      })

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      html =
        view
        |> element("button[phx-click='set_run_detail_panel_tab'][phx-value-tab='settings']")
        |> render_click()

      assert html =~ "Settings used"
      assert html =~ "Attempt workflow fingerprint"
      assert html =~ "attempt-sha-123"
      assert html =~ "Workflow version"
      assert html =~ "v1.2.3"
      assert html =~ "Main agent"
      assert html =~ "claude 7200000ms (/usr/bin/claude)"
      assert html =~ "Review agent"
      assert html =~ "cursor 600000ms (/usr/bin/cursor-review)"
      assert html =~ "Review cycles"
      assert html =~ "2"
      assert html =~ "Checks"
      assert html =~ "Enabled (2 required)"
      assert html =~ "Review"
      assert html =~ "Enabled"
      assert html =~ "Publish"
      assert html =~ "Enabled (pr, github)"
      assert html =~ "Runtime"
      assert html =~ "Enabled (pitchfork, 1 process)"
      assert html =~ "Current WORKFLOW.md fingerprint differs from this run attempt."
    end

    test "run detail shows legacy fallback when snapshot is unavailable", %{
      conn: conn,
      project: project
    } do
      story_id = "US-LEGACY-SNAPSHOT"
      _ = prepare_run_logs!(project.slug, story_id)

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Back to Runs"
      refute html =~ "set_run_detail_panel_tab"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Legacy snapshot",
        "status" => "done"
      })

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      html =
        view
        |> element("button[phx-click='set_run_detail_panel_tab'][phx-value-tab='settings']")
        |> render_click()

      assert html =~ "Settings used"
      assert html =~ "Settings snapshot unavailable."
      assert html =~ "Actions"
      assert html =~ "Retry unavailable for this run"
      refute html =~ "Full rerun"
      refute html =~ "Run finished"
    end

    test "run detail shows testing report checkpoints and artifacts", %{
      conn: conn,
      project: project
    } do
      story_id = "US-TESTING-REPORT"

      context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :testing_started, cycle: 1},
            %{
              type: :testing_checkpoint,
              name: "acceptance flow",
              status: "pass",
              details: "validated end-to-end"
            },
            %{type: :testing_passed, summary: "Testing completed successfully"}
          ]
        )

      report = %{
        "verdict" => "pass",
        "summary" => "Testing completed successfully",
        "checkpoints" => [
          %{"name" => "acceptance flow", "status" => "pass", "details" => "validated end-to-end"}
        ],
        "artifacts" => [
          %{
            "kind" => "screenshot",
            "path" => "artifacts/testing-success.png",
            "stored_path" => Path.join(context.files.testing_artifacts_dir, "001_smoke.png")
          },
          %{
            "kind" => "video",
            "path" => "artifacts/testing-success.webm",
            "stored_path" => Path.join(context.files.testing_artifacts_dir, "002_demo.webm")
          },
          %{
            "kind" => "replay",
            "path" => "https://agent-browser.local/replays/testing-success"
          }
        ]
      }

      File.mkdir_p!(context.files.testing_artifacts_dir)
      File.mkdir_p!(context.files.testing_cycles_dir)
      File.write!(Path.join(context.files.testing_artifacts_dir, "001_smoke.png"), "png")
      File.write!(Path.join(context.files.testing_artifacts_dir, "002_demo.webm"), "webm")

      File.write!(
        Path.join(context.files.testing_cycles_dir, "cycle-001.json"),
        Jason.encode!(report, pretty: true)
      )

      File.write!(context.files.testing_report, Jason.encode!(report, pretty: true))
      RunLogs.complete_attempt(context, %{status: "ok"})

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Testing"
      assert html =~ "/projects/#{project.slug}/runs/#{story_id}/1/step/0"
      refute html =~ "set_run_detail_panel_tab"

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1/step/0")

      step_html = render(view)

      assert step_html =~ "Back to Steps"
      assert step_html =~ "Testing"
      assert step_html =~ "Logs"
      assert step_html =~ "Reports"

      preview_url = "/projects/#{project.slug}/runs/#{story_id}/1/artifacts/001_smoke.png"

      preview_html =
        render_hook(view, "open_artifact_preview", %{
          "url" => preview_url,
          "type" => "image",
          "title" => "smoke screenshot"
        })

      assert preview_html =~ "Artifact preview"
      assert preview_html =~ preview_url

      assert preview_html =~ ~s(phx-click="close_artifact_preview")
    end

    test "step detail shows prompt tab for agent, review, and testing phases", %{
      conn: conn,
      project: project
    } do
      story_id = "US-STEP-PROMPTS"

      prepare_run_logs!(project.slug, story_id,
        events: [
          %{type: :quality_cycle_started, cycle: 1},
          %{type: :prompt_captured, phase: :agent, prompt: "Agent first prompt"},
          %{type: :turn_started, turn: 1},
          %{type: :turn_succeeded, turn: 1, output: "agent output"},
          %{type: :review_started, cycle: 1},
          %{type: :prompt_captured, phase: :review, prompt: "Review first prompt"},
          %{type: :review_passed, cycle: 1, output: "review output"},
          %{type: :testing_started, cycle: 1},
          %{type: :prompt_captured, phase: :testing, prompt: "Testing first prompt"},
          %{type: :testing_passed, cycle: 1, output: "testing output"}
        ],
        status: "ok"
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      step_paths =
        Regex.scan(~r|/projects/#{project.slug}/runs/#{story_id}/1/step/\d+|, html)
        |> List.flatten()
        |> Enum.uniq()

      assert length(step_paths) == 3

      [agent_step_path, review_step_path, testing_step_path] = step_paths

      {:ok, agent_view, _html} = live(conn, agent_step_path)

      agent_prompt_html =
        agent_view
        |> element("button[phx-click='set_step_detail_tab'][phx-value-tab='prompt']")
        |> render_click()

      assert agent_prompt_html =~ "Agent first prompt"

      {:ok, review_view, _html} = live(conn, review_step_path)

      review_prompt_html =
        review_view
        |> element("button[phx-click='set_step_detail_tab'][phx-value-tab='prompt']")
        |> render_click()

      assert review_prompt_html =~ "Review first prompt"

      {:ok, testing_view, _html} = live(conn, testing_step_path)

      testing_prompt_html =
        testing_view
        |> element("button[phx-click='set_step_detail_tab'][phx-value-tab='prompt']")
        |> render_click()

      assert testing_prompt_html =~ "Testing first prompt"
    end

    test "run detail reports tab shows review report json view", %{
      conn: conn,
      project: project
    } do
      story_id = "US-REVIEW-REPORT"

      context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :review_started, cycle: 1},
            %{
              type: :review_failed,
              reason: "Found blocking review issue",
              finding: "Missing regression test coverage"
            }
          ],
          status: "failed"
        )

      review_report = %{
        "verdict" => "fail",
        "summary" => "Found blocking review issue",
        "findings" => [
          %{"severity" => "critical", "description" => "Missing regression test coverage"}
        ]
      }

      File.mkdir_p!(context.files.review_cycles_dir)

      File.write!(
        Path.join(context.files.review_cycles_dir, "cycle-001.json"),
        Jason.encode!(review_report, pretty: true)
      )

      File.write!(context.files.review_json, Jason.encode!(review_report, pretty: true))
      RunLogs.complete_attempt(context, %{status: "failed"})

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Review"
      assert html =~ "/projects/#{project.slug}/runs/#{story_id}/1/step/0"
      refute html =~ "set_run_detail_panel_tab"

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1/step/0")

      step_html = render(view)

      assert step_html =~ "Back to Steps"
      assert step_html =~ "Review"
      assert step_html =~ "Logs"
      assert step_html =~ "Reports"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Review report",
        "status" => "failed"
      })

      {:ok, view2, _html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      html =
        view2
        |> element("button[phx-click='set_run_detail_panel_tab'][phx-value-tab='reports']")
        |> render_click()

      assert html =~ "Review"
      assert html =~ "Testing"
      assert html =~ "Review report"
      refute html =~ "Testing report"
      assert html =~ "FAIL"
      assert html =~ "Found blocking review issue"
      assert html =~ "Missing regression test coverage"
      assert html =~ "Per-cycle review.json"
      assert html =~ "Raw review.json"
    end

    test "run detail shows enabled retry action for failed checks attempt", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      story_id = "US-RETRY-CHECKS"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Retry checks",
        "status" => "failed"
      })

      write_workflow!(project, """
      ---
      tracker:
        kind: prd_json
      workspace:
        strategy: clone
      agent:
        kind: amp
        command: /bin/true
      quality:
        max_cycles: 1
        checks:
          required:
            - test -f ready.txt
          timeout_ms: 10000
          fail_fast: true
          max_cycles: 1
        review:
          enabled: false
          max_cycles: 1
      publish:
        mode: push
      orchestrator:
        retries_enabled: false
      git:
        base_branch: main
      ---

      Work on {{ issue.identifier }}.
      """)

      workspace_path = Path.join(tmp_dir, "retry-checks-workspace")
      File.mkdir_p!(workspace_path)
      File.write!(Path.join(workspace_path, "ready.txt"), "ok\n")

      _context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :turn_succeeded, turn: 1, output: "agent output"},
            %{type: :checks_started, check_count: 1},
            %{type: :check_failed, check_index: 1, reason: "failed"},
            %{type: :checks_failed, error_count: 1}
          ],
          status: "failed",
          completion: %{workspace_path: workspace_path, error: "checks failed"}
        )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Checks"
      refute html =~ "set_run_detail_panel_tab"

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Actions"
      assert has_element?(view, "button[phx-click='trigger_run'][phx-value-step='checks']")
      assert html =~ "Retry checks"
      refute html =~ ~s(phx-value-step="checks" disabled)
    end

    test "runtime healthcheck failure shows retry-from-step and retry testing action", %{
      conn: conn,
      project: project,
      tmp_dir: tmp_dir
    } do
      story_id = "US-RETRY-RUNTIME"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Retry runtime",
        "status" => "failed"
      })

      write_workflow!(project, """
      ---
      tracker:
        kind: prd_json
      workspace:
        strategy: clone
      agent:
        kind: amp
        command: /bin/true
      quality:
        max_cycles: 1
        checks:
          required: []
          timeout_ms: 10000
          fail_fast: true
          max_cycles: 1
        review:
          enabled: false
          max_cycles: 1
        testing:
          enabled: true
          max_cycles: 1
          timeout_ms: 10000
          agent:
            kind: amp
            command: /bin/true
            args: []
            env: {}
            timeout_ms: 10000
      runtime:
        kind: host
        processes:
          - server
        env: {}
        ports: {}
        start_timeout_ms: 10000
        stop_timeout_ms: 10000
      publish:
        mode: push
      orchestrator:
        retries_enabled: false
      git:
        base_branch: main
      ---

      Work on {{ issue.identifier }}.
      """)

      workspace_path = Path.join(tmp_dir, "retry-runtime-workspace")
      File.mkdir_p!(workspace_path)

      _context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :runtime_starting, command: "docker", workspace_path: workspace_path},
            %{type: :runtime_started, command: "docker", resolved_ports: %{"PORT" => 4921}},
            %{type: :runtime_healthcheck_started, resolved_ports: %{"PORT" => 4921}},
            %{
              type: :runtime_healthcheck_failed,
              reason: "ports not reachable before timeout: PORT=4921",
              resolved_ports: %{"PORT" => 4921}
            },
            %{type: :runtime_stopping, command: "docker"},
            %{type: :runtime_stopped, command: "docker"}
          ],
          status: "failed",
          completion: %{workspace_path: workspace_path, error: "runtime healthcheck failed"}
        )

      {:ok, run_view, run_html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert run_html =~ "Runtime Start"
      assert has_element?(run_view, "button[phx-click='trigger_run'][phx-value-step='testing']")

      {:ok, story_view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Actions"
      assert html =~ "Retry testing"
      assert has_element?(story_view, "button[phx-click='trigger_run'][phx-value-step='testing']")
      refute html =~ ~s(phx-value-step="testing" disabled)

      html =
        run_view
        |> element("button[phx-click='trigger_run'][phx-value-step='testing']")
        |> render_click()

      assert html =~ "Confirm action"
      assert html =~ "Start retry testing"

      _html =
        run_view
        |> element("button[phx-click='cancel_action_confirmation']", "Cancel")
        |> render_click()

      refute has_element?(run_view, "button[data-confirm-action='trigger_run']")
    end

    test "run detail suppresses nil error banner for successful attempt metadata", %{
      conn: conn,
      project: project
    } do
      story_id = "US-NIL-ERROR"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Nil error banner",
        "status" => "done"
      })

      _context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :run_started},
            %{type: :run_finished, status: "ok"}
          ],
          status: "ok",
          completion: %{error: "nil"}
        )

      {:ok, _run_view, run_html} = live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      refute run_html =~ "alert alert-error"
      refute run_html =~ ">nil<"
    end

    test "run detail disables retry action when workspace preconditions are missing", %{
      conn: conn,
      project: project
    } do
      story_id = "US-RETRY-DISABLED"

      append_story!(project, %{
        "id" => story_id,
        "title" => "Retry disabled",
        "status" => "failed"
      })

      write_workflow!(project, """
      ---
      tracker:
        kind: prd_json
      workspace:
        strategy: clone
      agent:
        kind: amp
        command: /bin/true
      quality:
        max_cycles: 1
        checks:
          required:
            - test -f ready.txt
          timeout_ms: 10000
          fail_fast: true
          max_cycles: 1
        review:
          enabled: false
          max_cycles: 1
      publish:
        mode: push
      orchestrator:
        retries_enabled: false
      git:
        base_branch: main
      ---

      Work on {{ issue.identifier }}.
      """)

      _context =
        prepare_run_logs!(project.slug, story_id,
          events: [
            %{type: :turn_succeeded, turn: 1, output: "agent output"},
            %{type: :checks_started, check_count: 1},
            %{type: :check_failed, check_index: 1, reason: "failed"},
            %{type: :checks_failed, error_count: 1}
          ],
          status: "failed",
          completion: %{
            workspace_path:
              Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer()}"),
            error: "checks failed"
          }
        )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Pipeline Steps"
      assert html =~ "Checks"

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Actions"
      assert has_element?(view, "button[phx-click='trigger_run'][phx-value-step='checks']")
      assert html =~ "Retry checks"
      assert html =~ ~s(phx-value-step="checks" disabled)
      assert html =~ "workspace is missing"
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
      assert html =~ "Stop Work"
    end

    test "runs page uses latest run logs over stale tracker last-run metadata", %{
      conn: conn,
      project: project
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
        Projects.tracker_path(project),
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
      project: project
    } do
      stories = [
        %{
          "id" => "US-NO-LAST",
          "title" => "No Last Attempt",
          "status" => "done"
        }
      ]

      File.write!(
        Projects.tracker_path(project),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      _ = prepare_run_logs!(project.slug, "US-NO-LAST")

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "/projects/#{project.slug}/runs/US-NO-LAST/1"
      assert html =~ "#1"
    end

    test "runs page shows derived phase label for attempts", %{conn: conn, project: project} do
      _ =
        prepare_run_logs!(project.slug, "US-PHASE-RUN",
          events: [
            %{type: :checks_started, check_count: 2},
            %{type: :check_started, check_index: 1}
          ],
          status: "running"
        )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "Checks 1/2"
    end

    test "runs page keeps retry controls out of compact table view", %{
      conn: conn,
      project: project
    } do
      _ =
        prepare_run_logs!(project.slug, "US-CONTINUATION",
          retry_mode: :agent_continuation,
          retry_provenance: %{
            originating_attempt: 1,
            last_successful_turn: 3,
            failure_reason: "agent timed out"
          }
        )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      refute html =~ "Agent continuation"
      refute html =~ "from run #1, turn 3 (agent timed out)"
      refute html =~ "<th>Retry</th>"
    end

    test "runs page moves past transient checks_failed once remediation turn starts", %{
      conn: conn,
      project: project
    } do
      _ =
        prepare_run_logs!(project.slug, "US-REMEDIATION-PHASE",
          events: [
            %{type: :checks_failed, error_count: 1},
            %{type: :turn_started, turn: 2}
          ],
          status: "running"
        )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "Agent turn 2"
      refute html =~ "Checks failed"
    end

    test "runs page preserves failed terminal status when terminal event is missing", %{
      conn: conn,
      project: project
    } do
      _ =
        prepare_run_logs!(project.slug, "US-FAILED-PHASE",
          events: [
            %{type: :checks_started, check_count: 2},
            %{type: :check_started, check_index: 1}
          ],
          status: "failed"
        )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs")

      assert html =~ "Run failed"
      refute html =~ "Checks 1/2"
    end

    test "stories page shows last run phase label", %{conn: conn, project: project} do
      _ =
        prepare_run_logs!(project.slug, "US-001",
          events: [
            %{type: :turn_started, turn: 2}
          ],
          status: "running"
        )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      assert html =~ "Last run: Agent turn 2"
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

    test "run detail shows continuation retry provenance", %{conn: conn, project: project} do
      story_id = "US-RUN-DETAIL-CONTINUATION"

      _ =
        prepare_run_logs!(project.slug, story_id,
          retry_mode: :agent_continuation,
          retry_provenance: %{
            originating_attempt: 2,
            last_successful_turn: 4,
            failure_reason: "agent-phase timeout"
          }
        )

      append_story!(project, %{
        "id" => story_id,
        "title" => "Continuation",
        "status" => "in_progress"
      })

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "from run #2, turn 4 (agent-phase timeout)"
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

    test "agent tab renders cursor stream-json logs as readable text", %{
      conn: conn,
      project: project
    } do
      story_id = "US-CURSOR-STREAM"
      context = prepare_run_logs!(project.slug, story_id)

      File.write!(
        context.files.agent_stdout,
        """
        {"type":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":" on"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":" it"}]}}
        {"type":"tool_call","subtype":"started","tool_call":{"shellToolCall":{"args":{"command":"mix test"}}}}
        {"type":"tool_call","subtype":"completed","tool_call":{"shellToolCall":{"args":{"command":"mix test"}}}}
        """
      )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs")

      assert html =~ "Working on it"
      assert html =~ "[tool started] shell: mix test"
      assert html =~ "[tool completed] shell: mix test"
      refute html =~ "&quot;type&quot;:&quot;assistant&quot;"
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

    test "log_tab query preserves selected testing log across refresh", %{
      conn: conn,
      project: project
    } do
      story_id = "US-LOG-TAB-KEEP"
      context = prepare_run_logs!(project.slug, story_id, status: "running")

      File.write!(context.files.agent_stdout, "agent content")
      File.write!(context.files.tester_stdout, "testing content")

      {:ok, view, html} =
        live(
          conn,
          ~p"/projects/#{project.slug}/stories/#{story_id}?attempt=1&tab=runs&log_tab=testing_agent"
        )

      assert html =~ "testing content"
      refute html =~ "agent content"

      File.write!(context.files.tester_stdout, "testing content updated")
      send(view.pid, :poll_logs)

      html = render(view)
      assert html =~ "testing content updated"
      refute html =~ "agent content"

      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "testing content updated"
      refute html =~ "agent content"
    end
  end

  describe "story sort order" do
    test "done stories are ordered most-recent-first by completedAt", %{
      conn: conn,
      project: project
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
        Projects.tracker_path(project),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      newer_pos = :binary.match(html, "US-NEW") |> elem(0)
      older_pos = :binary.match(html, "US-OLD") |> elem(0)
      assert newer_pos < older_pos
    end

    test "open stories appear before in_progress stories in rendered HTML", %{
      conn: conn,
      project: project
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
        Projects.tracker_path(project),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/stories")

      ip_pos = :binary.match(html, "US-IP") |> elem(0)
      open_pos = :binary.match(html, "US-OPEN") |> elem(0)
      assert open_pos < ip_pos
    end
  end

  defp prepare_run_logs!(project_slug, story_id, opts \\ []) do
    config = %Config{
      workspace: %{root: Path.join(System.tmp_dir!(), "kollywood_dashboard_workspaces")},
      tracker: %{path: nil, project_slug: project_slug}
    }

    issue = %{id: story_id, identifier: story_id, title: "Test #{story_id}"}
    retry_mode = Keyword.get(opts, :retry_mode, :full_rerun)
    retry_provenance = Keyword.get(opts, :retry_provenance, %{})
    metadata_overrides = Keyword.get(opts, :metadata_overrides, %{})

    {:ok, context} =
      RunLogs.prepare_attempt(config, issue, nil,
        retry_mode: retry_mode,
        retry_provenance: retry_provenance,
        metadata_overrides: metadata_overrides
      )

    opts
    |> Keyword.get(:events, [])
    |> Enum.each(fn event ->
      RunLogs.append_event(context, event)
    end)

    completion =
      opts
      |> Keyword.get(:completion, %{})
      |> Map.new()
      |> Map.put_new(:status, Keyword.get(opts, :status, "finished"))
      |> Map.put_new(:turn_count, Keyword.get(opts, :turn_count, 1))

    RunLogs.complete_attempt(context, completion)

    context
  end

  defp settings_snapshot_fixture do
    %{
      "schema_version" => 1,
      "captured_at" => "2026-03-29T00:00:00Z",
      "workflow" => %{
        "path" => "/tmp/attempt-workflow.md",
        "sha256" => "attempt-sha-123",
        "identity_source" => "workflow_file",
        "version" => "v1.2.3"
      },
      "resolved" => %{
        "agent" => %{
          "kind" => "claude",
          "command" => "/usr/bin/claude",
          "timeout_ms" => 7_200_000
        },
        "review" => %{
          "enabled" => true,
          "max_cycles" => 2,
          "agent" => %{
            "kind" => "cursor",
            "command" => "/usr/bin/cursor-review",
            "timeout_ms" => 600_000
          }
        },
        "checks" => %{
          "required" => ["mix test", "mix format --check-formatted"]
        },
        "publish" => %{
          "provider" => "github",
          "mode" => "pr"
        },
        "runtime" => %{
          "processes" => ["server"]
        }
      },
      "sources" => %{}
    }
  end

  describe "story detail settings tab inline edit" do
    test "settings tab shows execution overrides read-only by default", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      html =
        view
        |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
        |> render_click()

      assert html =~ "Execution Overrides"
      assert html =~ "Edit Overrides"
      assert html =~ "Agent Kind"
      assert html =~ "Testing Enabled"
      assert html =~ "workflow default"
      refute html =~ ~s(name="overrides[testing_enabled]")
    end

    test "clicking Edit Overrides enters edit mode with form controls", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_settings_edit']")
        |> render_click()

      assert html =~ ~s(name="overrides[testing_enabled]")
      assert html =~ ~s(name="overrides[agent_kind]")
      assert html =~ ~s(name="overrides[review_max_cycles]")
      assert html =~ "Save"
      assert html =~ "Cancel"
      assert html =~ "Use workflow default"
      refute html =~ "Edit Overrides"
    end

    test "cancel exits edit mode back to read-only", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_settings_edit']")
      |> render_click()

      assert has_element?(view, "button", "Cancel")

      html =
        view
        |> element("button[phx-click='toggle_settings_edit']", "Cancel")
        |> render_click()

      assert html =~ "Edit Overrides"
      refute html =~ ~s(name="overrides[testing_enabled]")
    end

    test "switching tabs resets edit mode", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_settings_edit']")
      |> render_click()

      assert has_element?(view, "form[phx-submit='save_story_overrides']")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='details']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
        |> render_click()

      assert html =~ "Edit Overrides"
      refute html =~ ~s(name="overrides[testing_enabled]")
    end

    test "saving overrides persists settings.execution and shows in read-only view", %{
      conn: conn,
      project: project
    } do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-001")

      settings_html =
        view
        |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
        |> render_click()

      assert settings_html =~ "Execution Overrides"

      edit_html =
        view
        |> element("button[phx-click='toggle_settings_edit']")
        |> render_click()

      assert edit_html =~ ~s(name="overrides[testing_enabled]")

      html =
        view
        |> element("form[phx-submit='save_story_overrides']")
        |> render_submit(%{
          overrides: %{
            "testing_enabled" => "true",
            "agent_kind" => "claude",
            "review_max_cycles" => "3",
            "review_agent_kind" => "",
            "testing_agent_kind" => "",
            "testing_max_cycles" => "",
            "preview_enabled" => ""
          }
        })

      assert html =~ "overridden"
      assert html =~ "Edit Overrides"

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-001"))
      assert story["settings"]["execution"]["testing_enabled"] == true
      assert story["settings"]["execution"]["agent_kind"] == "claude"
      assert story["settings"]["execution"]["review_max_cycles"] == 3
      refute Map.has_key?(story["settings"]["execution"], "review_agent_kind")
      refute Map.has_key?(story["settings"]["execution"], "preview_enabled")
    end

    test "edit form is prefilled with existing override values", %{
      conn: conn,
      project: project
    } do
      stories = [
        %{
          "id" => "US-PREFILL",
          "title" => "Prefill Test",
          "status" => "open",
          "settings" => %{
            "execution" => %{
              "testing_enabled" => true,
              "agent_kind" => "claude",
              "review_max_cycles" => 5
            }
          }
        }
      ]

      File.write!(
        Projects.tracker_path(project),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-PREFILL")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
      |> render_click()

      html =
        view
        |> element("button[phx-click='toggle_settings_edit']")
        |> render_click()

      assert html =~ ~s(value="true" selected)
      assert html =~ ~s(value="claude" selected)
      assert html =~ ~s(value="5")
    end

    test "clearing overrides removes settings.execution keys", %{
      conn: conn,
      project: project
    } do
      stories = [
        %{
          "id" => "US-CLEAR",
          "title" => "Clear Test",
          "status" => "open",
          "settings" => %{
            "execution" => %{
              "testing_enabled" => true,
              "agent_kind" => "claude"
            }
          }
        }
      ]

      File.write!(
        Projects.tracker_path(project),
        Jason.encode!(%{"userStories" => stories}, pretty: true)
      )

      {:ok, view, _html} = live(conn, ~p"/projects/#{project.slug}/stories/US-CLEAR")

      view
      |> element("button[phx-click='set_story_tab'][phx-value-tab='settings']")
      |> render_click()

      view
      |> element("button[phx-click='toggle_settings_edit']")
      |> render_click()

      html =
        view
        |> element("form[phx-submit='save_story_overrides']")
        |> render_submit(%{
          overrides: %{
            "testing_enabled" => "",
            "agent_kind" => "",
            "review_agent_kind" => "",
            "review_max_cycles" => "",
            "testing_agent_kind" => "",
            "testing_max_cycles" => "",
            "preview_enabled" => ""
          }
        })

      assert html =~ "Edit Overrides"

      {:ok, content} = File.read(Projects.tracker_path(project))
      {:ok, data} = Jason.decode(content)
      story = Enum.find(data["userStories"], &(&1["id"] == "US-CLEAR"))
      execution = get_in(story, ["settings", "execution"]) || %{}
      assert execution == %{}
    end
  end

  defp append_story!(project, story) do
    tracker_path = Projects.tracker_path(project)
    {:ok, content} = File.read(tracker_path)
    {:ok, decoded} = Jason.decode(content)
    stories = Map.get(decoded, "userStories", [])
    payload = Map.put(decoded, "userStories", stories ++ [story])
    File.write!(tracker_path, Jason.encode!(payload, pretty: true))
  end

  defp write_workflow!(project, content) do
    workflow_path = Projects.workflow_path(project)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, content)
  end
end
