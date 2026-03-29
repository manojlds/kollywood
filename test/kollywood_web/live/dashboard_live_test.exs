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

      html = render(view)

      draft_pos = :binary.match(html, ~s(id="stories-column-draft")) |> elem(0)
      open_pos = :binary.match(html, ~s(id="stories-column-open")) |> elem(0)
      ip_pos = :binary.match(html, ~s(id="stories-column-in_progress")) |> elem(0)
      done_pos = :binary.match(html, ~s(id="stories-column-done")) |> elem(0)
      merged_pos = :binary.match(html, ~s(id="stories-column-merged")) |> elem(0)
      failed_pos = :binary.match(html, ~s(id="stories-column-failed")) |> elem(0)

      assert draft_pos < open_pos
      assert open_pos < ip_pos
      assert ip_pos < done_pos
      assert done_pos < merged_pos
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
      assert has_element?(view, "#stories-list-group-content-draft")

      html = render(view)
      draft_pos = :binary.match(html, ~s(id="stories-list-group-draft")) |> elem(0)
      open_pos = :binary.match(html, ~s(id="stories-list-group-open")) |> elem(0)
      ip_pos = :binary.match(html, ~s(id="stories-list-group-in_progress")) |> elem(0)
      assert draft_pos < open_pos
      assert open_pos < ip_pos

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

      assert render(view) =~
               "Stop work on US-002? This will stop any in-progress run, move it to Draft, clear run data, and remove the worktree."

      html =
        view
        |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
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

      view
      |> element("button[phx-click='reset_story'][phx-value-id='US-002']")
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
          metadata_overrides: %{"settings_snapshot" => settings_snapshot_fixture()}
        )

      {:ok, _view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

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
      assert html =~ "Enabled (devenv, 1 process)"
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
      context = prepare_run_logs!(project.slug, story_id)

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

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      html =
        view
        |> element("button[phx-click='set_run_detail_panel_tab'][phx-value-tab='reports']")
        |> render_click()

      assert html =~ "Testing report"
      assert html =~ "PASS"
      assert html =~ "Testing completed successfully"
      assert html =~ "acceptance flow"
      assert html =~ "artifacts/testing-success.png"
      assert html =~ "agent-browser.local/replays/testing-success"
      assert html =~ "Per-cycle testing.json"
      assert html =~ ~s(/projects/#{project.slug}/runs/#{story_id}/1/artifacts/001_smoke.png)
      assert html =~ ~s(/projects/#{project.slug}/runs/#{story_id}/1/artifacts/002_demo.webm)
    end

    test "run detail reports tab shows review report json view", %{
      conn: conn,
      project: project
    } do
      story_id = "US-REVIEW-REPORT"
      context = prepare_run_logs!(project.slug, story_id)

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

      {:ok, view, _html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      html =
        view
        |> element("button[phx-click='set_run_detail_panel_tab'][phx-value-tab='reports']")
        |> render_click()

      assert html =~ "Review report"
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

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Actions"
      assert has_element?(view, "button[phx-click='trigger_run'][phx-value-step='checks']")
      assert html =~ "Retry checks"
      refute html =~ ~s(phx-value-step="checks" disabled)
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

      {:ok, view, html} =
        live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

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

      {:ok, _view, html} = live(conn, ~p"/projects/#{project.slug}/runs/#{story_id}/1")

      assert html =~ "Agent continuation"
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
          "command" => "devenv",
          "processes" => ["server"]
        }
      },
      "sources" => %{}
    }
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
