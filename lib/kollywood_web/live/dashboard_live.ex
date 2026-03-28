defmodule KollywoodWeb.DashboardLive do
  @moduledoc """
  Project-scoped dashboard with navigation, real story/run data,
  and run detail with logs.
  """
  use KollywoodWeb, :live_view
  require Logger

  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.ServiceConfig
  alias Kollywood.Tracker.PrdJson

  @default_stories_view "kanban"
  @story_status_columns [
    {"in_progress", "In Progress"},
    {"open", "Open"},
    {"done", "Done"},
    {"merged", "Merged"},
    {"failed", "Failed"},
    {"draft", "Draft"}
  ]
  @primary_story_status_columns [
    {"in_progress", "In Progress"},
    {"open", "Open"},
    {"done", "Done"},
    {"merged", "Merged"},
    {"failed", "Failed"}
  ]

  @impl true
  def mount(params, _session, socket) do
    projects = Projects.list_enabled_projects()
    current_project = find_project_by_slug(projects, params["project_slug"])

    if connected?(socket), do: :timer.send_interval(5_000, self(), :refresh)

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:current_project, current_project)
      |> assign(:current_scope, nil)
      |> assign(:selected_story, nil)
      |> assign(:story_detail_tab, "details")
      |> assign(:active_log_tab, "agent")
      |> assign(:log_poll_timer, nil)
      |> assign(:story_form_mode, nil)
      |> assign(:story_form_values, %{})
      |> assign(:story_form_story_id, nil)
      |> assign(:story_form_error, nil)
      |> assign(:stories_view, @default_stories_view)
      |> assign(:workflow, %{
        yaml: "",
        body: "",
        parsed: %{},
        review_template: "",
        review_template_is_default: true,
        error: nil,
        path: nil
      })
      |> assign(:page_title, if(current_project, do: current_project.name, else: "Dashboard"))
      |> assign(:orchestrator_status, fetch_orchestrator_status())
      |> load_project_data(current_project)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = cancel_poll_timer(socket)
    project_slug = params["project_slug"]
    current_project = find_project_by_slug(socket.assigns.projects, project_slug)

    socket =
      socket
      |> assign(:current_project, current_project)
      |> assign(:page_title, if(current_project, do: current_project.name, else: "Dashboard"))
      |> assign(:run_detail_story_id, params["story_id"])
      |> assign(:run_detail_attempt, params["attempt"])
      |> assign(:stories_view, @default_stories_view)
      |> load_project_data(current_project)
      |> handle_live_action(socket.assigns[:live_action], params)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_project_data(socket.assigns.current_project)
      |> sync_story_detail_selection()
      |> assign(:orchestrator_status, fetch_orchestrator_status())

    {:noreply, socket}
  end

  def handle_info(:poll_logs, socket) do
    story_id = socket.assigns.run_detail_story_id
    tab = socket.assigns.active_log_tab
    run_detail = load_run_detail_latest(socket.assigns.current_project, story_id, tab)
    socket = assign(socket, :run_detail, run_detail)

    if run_detail && get_in(run_detail, ["metadata", "status"]) == "running" do
      {:noreply, socket}
    else
      {:noreply, cancel_poll_timer(socket)}
    end
  end

  @impl true
  def handle_event("set_log_tab", %{"tab" => tab}, socket) do
    story_id = socket.assigns.run_detail_story_id
    run_detail = load_run_detail_latest(socket.assigns.current_project, story_id, tab)

    socket =
      socket
      |> assign(:active_log_tab, tab)
      |> assign(:run_detail, run_detail)

    {:noreply, socket}
  end

  def handle_event("set_story_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :story_detail_tab, tab)}
  end

  def handle_event("set_stories_view", %{"view" => view}, socket) do
    {:noreply, assign(socket, :stories_view, normalize_stories_view(view))}
  end

  def handle_event("close_story", _params, socket) do
    {:noreply, assign(socket, :selected_story, nil)}
  end

  def handle_event("update_story_status", %{"id" => id, "status" => status}, socket) do
    project = socket.assigns.current_project

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          case PrdJson.set_manual_status(tracker_path, id, status) do
            :ok ->
              socket
              |> load_project_data(project)
              |> sync_story_detail_selection()
              |> put_flash(:info, "Story status updated.")

            {:error, reason} ->
              put_flash(socket, :error, "Status update failed: #{reason}")
          end

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("reset_story", %{"id" => id}, socket) do
    project = socket.assigns.current_project

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          case PrdJson.reset_story(tracker_path, id) do
            :ok ->
              cleanup_worktree(project, id)

              socket
              |> load_project_data(project)
              |> sync_story_detail_selection()
              |> put_flash(:info, "Story reset for rerun.")

            {:error, reason} ->
              put_flash(socket, :error, "Reset failed: #{reason}")
          end

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("open_new_story_form", _params, socket) do
    project = socket.assigns.current_project

    socket =
      case local_tracker_path(project) do
        {:ok, _tracker_path} ->
          socket
          |> assign(:story_form_mode, :new)
          |> assign(:story_form_story_id, nil)
          |> assign(:story_form_error, nil)
          |> assign(:story_form_values, default_story_form_values(socket.assigns.stories))

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("open_edit_story_form", %{"id" => story_id}, socket) do
    story = Enum.find(socket.assigns.stories, &(&1["id"] == story_id))

    socket =
      case story do
        nil ->
          put_flash(socket, :error, "Story not found: #{story_id}")

        story ->
          socket
          |> assign(:story_form_mode, :edit)
          |> assign(:story_form_story_id, story_id)
          |> assign(:story_form_error, nil)
          |> assign(:story_form_values, story_to_form_values(story))
      end

    {:noreply, socket}
  end

  def handle_event("cancel_story_form", _params, socket) do
    {:noreply, clear_story_form(socket)}
  end

  def handle_event("save_story", %{"story" => story_params}, socket) do
    project = socket.assigns.current_project
    mode = socket.assigns.story_form_mode
    story_id = socket.assigns.story_form_story_id

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          attrs = normalize_story_form_params(story_params)

          save_result =
            case mode do
              :new ->
                PrdJson.create_story(tracker_path, attrs)

              :edit when is_binary(story_id) ->
                PrdJson.update_story(tracker_path, story_id, attrs)

              _other ->
                {:error, "no story edit in progress"}
            end

          case save_result do
            {:ok, _story} ->
              socket
              |> clear_story_form()
              |> load_project_data(project)
              |> sync_story_detail_selection()
              |> put_flash(:info, "Story saved.")

            {:error, reason} ->
              socket
              |> assign(
                :story_form_values,
                merge_story_form_values(socket.assigns.story_form_values, attrs)
              )
              |> assign(:story_form_error, reason)
          end

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("delete_story", %{"id" => story_id}, socket) do
    project = socket.assigns.current_project

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          case PrdJson.delete_story(tracker_path, story_id) do
            :ok ->
              cleanup_worktree(project, story_id)

              socket
              |> clear_story_form_if_editing(story_id)
              |> load_project_data(project)
              |> sync_story_detail_selection()
              |> put_flash(:info, "Story deleted.")

            {:error, reason} ->
              put_flash(socket, :error, "Delete failed: #{reason}")
          end

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("trigger_run", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save_workflow", %{"body" => body}, socket) do
    project = socket.assigns.current_project
    yaml = socket.assigns.workflow.yaml

    socket =
      if local_provider?(project) do
        case workflow_path(project) do
          nil ->
            socket

          path ->
            content = "---\n#{String.trim(yaml)}\n---\n\n#{String.trim(body)}\n"

            case File.write(path, content) do
              :ok ->
                git_commit_workflow(path)

                socket
                |> assign(:workflow, load_workflow(project))
                |> put_flash(:info, "Prompt template saved.")

              {:error, reason} ->
                assign(
                  socket,
                  :workflow,
                  Map.put(socket.assigns.workflow, :error, "Save failed: #{inspect(reason)}")
                )
            end
        end
      else
        put_flash(socket, :error, "Workflow settings are read-only for remote providers.")
      end

    {:noreply, socket}
  end

  def handle_event("save_review_template", %{"review_template" => template}, socket) do
    project = socket.assigns.current_project

    socket =
      if local_provider?(project) do
        case workflow_path(project) do
          nil ->
            socket

          path ->
            trimmed = String.trim(template)
            default = String.trim(Kollywood.AgentRunner.default_review_prompt_template())

            with {:ok, content} <- File.read(path),
                 new_yaml <-
                   if(trimmed == default,
                     do: remove_review_template(content),
                     else: inject_review_template(content, trimmed)
                   ),
                 :ok <- File.write(path, new_yaml) do
              git_commit_workflow(path)

              socket
              |> assign(:workflow, load_workflow(project))
              |> put_flash(:info, "Review template saved.")
            else
              {:error, reason} ->
                assign(
                  socket,
                  :workflow,
                  Map.put(socket.assigns.workflow, :error, "Save failed: #{inspect(reason)}")
                )
            end
        end
      else
        put_flash(socket, :error, "Workflow settings are read-only for remote providers.")
      end

    {:noreply, socket}
  end

  def handle_event("save_settings", %{"settings" => settings}, socket) do
    project = socket.assigns.current_project

    socket =
      case workflow_path(project) do
        nil ->
          socket

        path ->
          workflow = socket.assigns.workflow
          new_parsed = apply_settings(workflow.parsed, settings)
          new_yaml = to_workflow_yaml(new_parsed)
          content = "---\n#{new_yaml}\n---\n\n#{workflow.body}\n"

          case File.write(path, content) do
            :ok ->
              socket
              |> assign(:workflow, load_workflow(project))
              |> put_flash(:info, "Settings saved.")

            {:error, reason} ->
              assign(
                socket,
                :workflow,
                Map.put(workflow, :error, "Save failed: #{inspect(reason)}")
              )
          end
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <header class="navbar bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8">
        <div class="flex-1 flex items-center gap-4">
          <.link navigate={~p"/"} class="flex items-center gap-2">
            <.icon name="hero-rocket-launch" class="size-6 text-primary" />
            <span class="text-xl font-bold">Kollywood</span>
          </.link>
        </div>

        <div class="flex-none flex items-center gap-4">
          <.link navigate={~p"/admin"} class="btn btn-ghost btn-sm gap-1">
            <.icon name="hero-cog-6-tooth" class="size-4" /> Admin
          </.link>
          <.orchestrator_indicator status={@orchestrator_status} />
          <div class="dropdown dropdown-end">
            <div tabindex="0" role="button" class="btn btn-outline btn-sm gap-2">
              <.icon name="hero-folder" class="size-4" />
              <%= if @current_project do %>
                {@current_project.name}
              <% else %>
                Select Project
              <% end %>
              <.icon name="hero-chevron-down" class="size-4" />
            </div>
            <ul
              tabindex="0"
              class="dropdown-content menu menu-sm bg-base-100 rounded-box z-[1] w-64 p-2 shadow-lg border border-base-300 mt-2"
            >
              <%= for project <- @projects do %>
                <li>
                  <.link
                    navigate={~p"/projects/#{project.slug}"}
                    class={[@current_project && @current_project.id == project.id && "bg-base-200"]}
                  >
                    <span class="truncate">{project.name}</span>
                    <%= if @current_project && @current_project.id == project.id do %>
                      <.icon name="hero-check" class="size-4 text-success" />
                    <% end %>
                  </.link>
                </li>
              <% end %>
            </ul>
          </div>
        </div>
      </header>

      <%= if @current_project do %>
        <nav class="bg-base-100 border-b border-base-300 px-4 sm:px-6 lg:px-8">
          <div class="flex gap-1 overflow-x-auto">
            <.nav_tab
              label="Overview"
              icon="hero-squares-2x2"
              active={@live_action == :overview}
              patch={~p"/projects/#{@current_project.slug}"}
            />
            <.nav_tab
              label="Stories"
              icon="hero-list-bullet"
              active={@live_action in [:stories, :story_detail]}
              patch={~p"/projects/#{@current_project.slug}/stories"}
            />
            <.nav_tab
              label="Runs"
              icon="hero-play"
              active={@live_action in [:runs, :run_detail]}
              patch={~p"/projects/#{@current_project.slug}/runs"}
            />
            <.nav_tab
              label="Settings"
              icon="hero-cog-6-tooth"
              active={@live_action == :settings}
              patch={~p"/projects/#{@current_project.slug}/settings"}
            />
          </div>
        </nav>

        <main class="px-4 sm:px-6 lg:px-8 py-6">
          <div class="max-w-7xl mx-auto">
            <%= case @live_action do %>
              <% :overview -> %>
                <.overview_section
                  counters={@counters}
                  stories={@stories}
                  orchestrator_status={@orchestrator_status}
                  project={@current_project}
                  recent_runs={@recent_runs}
                />
              <% :stories -> %>
                <.stories_section
                  stories={@stories}
                  project={@current_project}
                  stories_view={@stories_view}
                />
              <% :runs -> %>
                <.runs_section
                  run_attempts={@run_attempts}
                  project={@current_project}
                  stories={@stories}
                />
              <% :story_detail -> %>
                <.story_detail_section
                  story={@selected_story}
                  story_id={@run_detail_story_id}
                  run_detail={@run_detail}
                  active_log_tab={@active_log_tab}
                  story_detail_tab={@story_detail_tab}
                  project={@current_project}
                  story_attempts={Enum.filter(@run_attempts, &(&1.story_id == @run_detail_story_id))}
                  selected_attempt={@run_detail_attempt}
                />
              <% :run_detail -> %>
                <.run_detail_section
                  run_detail={@run_detail}
                  story_id={@run_detail_story_id}
                  attempt={@run_detail_attempt}
                  active_log_tab={@active_log_tab}
                  project={@current_project}
                />
              <% :settings -> %>
                <.settings_section
                  project={@current_project}
                  workflow={@workflow}
                  workflow_editable={local_provider?(@current_project)}
                />
              <% _ -> %>
                <.overview_section
                  counters={@counters}
                  stories={@stories}
                  orchestrator_status={@orchestrator_status}
                  project={@current_project}
                  recent_runs={@recent_runs}
                />
            <% end %>
          </div>
        </main>

        <.story_editor_modal
          mode={@story_form_mode}
          values={@story_form_values}
          error={@story_form_error}
        />

        <%!-- Story Detail Slide-over (stories list only) --%>
        <div
          id="story-backdrop"
          class={[
            "fixed inset-0 bg-black/50 z-40 transition-opacity duration-300",
            if(@selected_story && @live_action == :stories,
              do: "opacity-100 pointer-events-auto",
              else: "opacity-0 pointer-events-none"
            )
          ]}
          phx-click="close_story"
        />
        <div
          id="story-slide-over"
          class={[
            "fixed inset-y-0 right-0 w-full sm:w-[480px] bg-base-100 shadow-2xl z-50 overflow-y-auto transform transition-transform duration-300",
            if(@selected_story && @live_action == :stories,
              do: "translate-x-0",
              else: "translate-x-full"
            )
          ]}
        >
          <%= if @selected_story do %>
            <div class="p-6">
              <div class="flex items-start justify-between mb-6">
                <div class="flex items-center gap-2 flex-wrap">
                  <span class="badge badge-outline font-mono text-sm">
                    {@selected_story["id"]}
                  </span>
                  <.status_badge status={@selected_story["status"] || "open"} />
                </div>
                <button
                  id="close-story-btn"
                  phx-click="close_story"
                  class="btn btn-ghost btn-sm btn-circle"
                >
                  <.icon name="hero-x-mark" class="size-5" />
                </button>
              </div>

              <h2 class="text-xl font-bold mb-4">{@selected_story["title"]}</h2>

              <%= if @selected_story["description"] do %>
                <div class="mb-4">
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Description
                  </h3>
                  <div class="prose prose-sm max-w-none">
                    {raw(markdown_to_html(@selected_story["description"]))}
                  </div>
                </div>
              <% end %>

              <%= if criteria = @selected_story["acceptanceCriteria"] do %>
                <%= if present?(criteria) do %>
                  <div class="mb-4">
                    <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                      Acceptance Criteria
                    </h3>

                    <%= if is_list(criteria) do %>
                      <ul class="list-disc list-inside space-y-1">
                        <%= for criterion <- criteria do %>
                          <li class="text-sm">{criterion}</li>
                        <% end %>
                      </ul>
                    <% else %>
                      <div class="prose prose-sm max-w-none">
                        {raw(markdown_to_html(criteria))}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              <% end %>

              <%= if @selected_story["notes"] do %>
                <div class="mb-4">
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Notes
                  </h3>
                  <div class="prose prose-sm max-w-none text-base-content/70">
                    {raw(markdown_to_html(@selected_story["notes"]))}
                  </div>
                </div>
              <% end %>

              <%= if depends_on = @selected_story["dependsOn"] do %>
                <%= if depends_on != [] do %>
                  <div class="mb-4">
                    <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                      Depends On
                    </h3>
                    <div class="flex flex-wrap gap-2">
                      <%= for dep <- depends_on do %>
                        <span class="badge badge-outline font-mono text-xs">{dep}</span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              <% end %>

              <%= if @selected_story["priority"] do %>
                <div class="mb-4">
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Priority
                  </h3>
                  <span class="text-sm capitalize">{@selected_story["priority"]}</span>
                </div>
              <% end %>

              <%= if @selected_story["lastError"] do %>
                <div class="mb-4">
                  <h3 class="text-xs font-semibold text-error uppercase tracking-wide mb-2">
                    Last Error
                  </h3>
                  <p class="text-sm text-error bg-error/10 p-3 rounded-lg">
                    {@selected_story["lastError"]}
                  </p>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% else %>
        <main class="flex items-center justify-center px-4 py-32">
          <div class="text-center">
            <.icon name="hero-folder-open" class="size-16 text-base-content/20 mx-auto mb-4" />
            <h2 class="text-xl font-semibold mb-2">Project not found</h2>
            <p class="text-base-content/70 mb-6">
              The selected project does not exist.
            </p>
            <.link navigate={~p"/"} class="btn btn-primary">Back to Projects</.link>
          </div>
        </main>
      <% end %>
    </div>
    """
  end

  # -- Nav Tab Component --

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :patch, :string, required: true

  defp nav_tab(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap",
        "hover:text-base-content",
        @active && "border-primary text-primary",
        !@active && "border-transparent text-base-content/70 hover:border-base-300"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  # -- Overview Section --

  attr :counters, :map, required: true
  attr :stories, :list, default: []
  attr :orchestrator_status, :map, default: nil
  attr :project, Project, default: nil
  attr :recent_runs, :list, default: []

  defp overview_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <.orchestrator_status_bar status={@orchestrator_status} />
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <.stat_card title="Open" value={@counters.open} color="info" />
        <.stat_card title="In Progress" value={@counters.in_progress} color="warning" />
        <.stat_card title="Done" value={@counters.done} color="success" />
        <.stat_card title="Failed" value={@counters.failed} color="error" />
      </div>

      <div class="card bg-base-200 border border-base-300">
        <div class="card-body">
          <h3 class="card-title text-lg">Recent Activity</h3>
          <%= if @recent_runs == [] do %>
            <p class="text-base-content/60 py-4">No recent activity</p>
          <% else %>
            <div class="space-y-1 mt-2">
              <%= for run <- @recent_runs do %>
                <.link
                  navigate={~p"/projects/#{@project.slug}/runs/#{run.story_id}/#{run.attempt}"}
                  class="flex items-center gap-3 p-3 bg-base-100 rounded-lg hover:bg-base-300 transition-colors"
                >
                  <.run_status_badge status={run.status} />
                  <span class="font-mono text-xs text-base-content/60 shrink-0">{run.story_id}</span>
                  <span class="text-sm truncate flex-1">{run.story_title}</span>
                  <span class="text-xs text-base-content/50 shrink-0">
                    Run {run_number(run.attempt)}
                  </span>
                  <span class="text-xs text-base-content/50 shrink-0">
                    {time_ago(run.ended_at || run.started_at)}
                  </span>
                </.link>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # -- Stories Section --

  attr :stories, :list, required: true
  attr :project, Project, required: true
  attr :stories_view, :string, default: @default_stories_view

  defp stories_section(assigns) do
    groups = build_story_groups(assigns.stories)

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:editable, local_provider?(assigns.project))
      |> assign(:stories_view, normalize_stories_view(assigns.stories_view))

    ~H"""
    <div
      id="stories-section"
      class="space-y-6"
      phx-hook=".StoriesViewPreference"
      data-project-slug={@project.slug}
      data-current-view={@stories_view}
    >
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-2xl font-bold">Stories</h2>

        <div id="stories-view-toggle" class="join order-last sm:order-none">
          <button
            type="button"
            phx-click="set_stories_view"
            phx-value-view="list"
            class={[
              "btn btn-sm join-item",
              @stories_view == "list" && "btn-primary",
              @stories_view != "list" && "btn-ghost"
            ]}
            aria-pressed={@stories_view == "list"}
          >
            List
          </button>
          <button
            type="button"
            phx-click="set_stories_view"
            phx-value-view="kanban"
            class={[
              "btn btn-sm join-item",
              @stories_view == "kanban" && "btn-primary",
              @stories_view != "kanban" && "btn-ghost"
            ]}
            aria-pressed={@stories_view == "kanban"}
          >
            Kanban
          </button>
        </div>

        <%= if @editable do %>
          <button phx-click="open_new_story_form" class="btn btn-primary btn-sm gap-2">
            <.icon name="hero-plus" class="size-4" /> Add Story
          </button>
        <% end %>
      </div>

      <%= if @stories == [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-document-text" class="size-12 text-base-content/20 mb-2" />
            <p class="text-base-content/60">
              No stories yet. Add stories to prd.json to get started.
            </p>
          </div>
        </div>
      <% else %>
        <%= if @stories_view == "kanban" do %>
          <.stories_kanban_view groups={@groups} project={@project} editable={@editable} />
        <% else %>
          <.stories_list_view groups={@groups} project={@project} editable={@editable} />
        <% end %>
      <% end %>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StoriesViewPreference">
      export default {
        mounted() {
          this.restoreViewPreference()
          this.persistCurrentView()
        },

        updated() {
          this.persistCurrentView()
        },

        normalizeView(view) {
          if (view === "list" || view === "kanban") return view
          return null
        },

        preferenceKey() {
          const slug = this.el.dataset.projectSlug
          return slug ? `kollywood:stories-view:${slug}` : null
        },

        restoreViewPreference() {
          const key = this.preferenceKey()
          if (!key) return

          try {
            const stored = this.normalizeView(window.localStorage.getItem(key))
            const current = this.normalizeView(this.el.dataset.currentView)

            if (stored && stored !== current) {
              this.pushEvent("set_stories_view", {view: stored})
            }
          } catch (_error) {
            // Ignore localStorage errors.
          }
        },

        persistCurrentView() {
          const key = this.preferenceKey()
          const current = this.normalizeView(this.el.dataset.currentView)
          if (!key || !current) return

          try {
            window.localStorage.setItem(key, current)
          } catch (_error) {
            // Ignore localStorage errors.
          }
        }
      }
    </script>
    """
  end

  attr :groups, :map, required: true
  attr :project, Project, required: true
  attr :editable, :boolean, default: false

  defp stories_list_view(assigns) do
    assigns = assign(assigns, :status_columns, @primary_story_status_columns)

    ~H"""
    <div id="stories-list-view" class="space-y-6">
      <%= for {status, label} <- @status_columns do %>
        <% stories = Map.get(@groups, status, []) %>
        <%= if stories != [] do %>
          <section id={"stories-list-group-#{status}"}>
            <h3 class="mb-3 flex items-center gap-2 text-lg font-semibold">
              <.status_badge status={status} />
              {label}
              <span class="badge badge-sm badge-ghost">{length(stories)}</span>
            </h3>
            <div class="space-y-2">
              <%= for story <- stories do %>
                <.story_card story={story} project={@project} editable={@editable} />
              <% end %>
            </div>
          </section>
        <% end %>
      <% end %>

      <% draft_stories = Map.get(@groups, "draft", []) %>
      <%= if draft_stories != [] do %>
        <section id="stories-list-group-draft" class="opacity-70">
          <h3 class="mb-3 flex items-center gap-2 text-lg font-semibold">
            <.status_badge status="draft" /> Draft
            <span class="badge badge-sm badge-ghost">{length(draft_stories)}</span>
          </h3>
          <div class="space-y-2">
            <%= for story <- draft_stories do %>
              <.story_card story={story} project={@project} editable={@editable} />
            <% end %>
          </div>
        </section>
      <% end %>
    </div>
    """
  end

  attr :groups, :map, required: true
  attr :project, Project, required: true
  attr :editable, :boolean, default: false

  defp stories_kanban_view(assigns) do
    assigns = assign(assigns, :status_columns, @story_status_columns)

    ~H"""
    <div id="stories-kanban-view" class="-mx-2 overflow-x-auto px-2 pb-2">
      <div class="flex min-w-max gap-3 lg:min-w-0 lg:grid lg:grid-cols-3 xl:grid-cols-6">
        <%= for {status, label} <- @status_columns do %>
          <.stories_kanban_column
            status={status}
            label={label}
            stories={Map.get(@groups, status, [])}
            project={@project}
            editable={@editable}
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :status, :string, required: true
  attr :label, :string, required: true
  attr :stories, :list, default: []
  attr :project, Project, required: true
  attr :editable, :boolean, default: false

  defp stories_kanban_column(assigns) do
    assigns =
      assign(assigns, :column_classes, [
        "w-[17.5rem] shrink-0 rounded-xl border border-base-300 bg-base-200/60 sm:w-[19rem]",
        "lg:w-auto lg:min-w-0",
        assigns.status == "draft" && "opacity-80"
      ])

    ~H"""
    <section id={"stories-column-#{@status}"} class={@column_classes}>
      <header class="flex items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
        <div class="flex items-center gap-2">
          <.status_badge status={@status} />
          <span class="text-sm font-semibold">{@label}</span>
        </div>
        <span class="badge badge-sm badge-ghost">{length(@stories)}</span>
      </header>

      <div class="space-y-2 p-3">
        <%= if @stories == [] do %>
          <p class="px-1 py-4 text-xs text-base-content/40">No stories</p>
        <% else %>
          <%= for story <- @stories do %>
            <.story_card story={story} project={@project} editable={@editable} />
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  attr :story, :map, required: true
  attr :project, Project, required: true
  attr :editable, :boolean, default: false

  defp story_card(assigns) do
    status = normalize_status(assigns.story["status"])
    status_targets = manual_status_targets(assigns.story["status"])
    show_reset = status not in ["open", "draft"]

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:status_targets, status_targets)
      |> assign(:show_reset, show_reset)

    ~H"""
    <div
      id={"story-card-#{@story["id"]}"}
      class={[
        "card border border-base-300 bg-base-200 shadow-sm",
        @status == "draft" && "border-dashed"
      ]}
    >
      <div class="card-body gap-3 p-4">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0 flex-1 space-y-2">
            <div class="flex items-center justify-between gap-2">
              <.link
                navigate={~p"/projects/#{@project.slug}/stories/#{@story["id"]}"}
                class="font-mono text-sm font-semibold text-primary hover:underline"
              >
                {@story["id"]}
              </.link>
              <.status_badge status={@status} />
            </div>

            <.link
              navigate={~p"/projects/#{@project.slug}/stories/#{@story["id"]}"}
              class="line-clamp-2 text-left font-medium hover:text-primary"
            >
              {@story["title"]}
            </.link>

            <%= if @story["dependsOn"] && @story["dependsOn"] != [] do %>
              <div class="flex flex-wrap items-center gap-1">
                <span class="text-xs text-base-content/50">depends on:</span>
                <%= for dep <- @story["dependsOn"] do %>
                  <span class="badge badge-xs badge-outline">{dep}</span>
                <% end %>
              </div>
            <% end %>

            <%= if @story["priority"] do %>
              <p class="text-xs text-base-content/60">
                Priority: <span class="capitalize">{to_string(@story["priority"])}</span>
              </p>
            <% end %>
          </div>

          <%= if @editable do %>
            <.story_actions_menu
              story={@story}
              status_targets={@status_targets}
              show_reset={@show_reset}
            />
          <% end %>
        </div>

        <%= if @story["lastError"] do %>
          <p class="line-clamp-2 text-sm text-error">{@story["lastError"]}</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :story, :map, required: true
  attr :status_targets, :list, default: []
  attr :show_reset, :boolean, default: false

  defp story_actions_menu(assigns) do
    ~H"""
    <div class="shrink-0">
      <div class="dropdown dropdown-end">
        <label tabindex="0" class="btn btn-ghost btn-xs">
          <.icon name="hero-ellipsis-horizontal" class="size-4" />
        </label>
        <ul
          tabindex="0"
          class="dropdown-content menu menu-xs z-50 w-44 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
        >
          <li>
            <button phx-click="open_edit_story_form" phx-value-id={@story["id"]} class="text-xs">
              Edit Story
            </button>
          </li>
          <li>
            <button
              phx-click="delete_story"
              phx-value-id={@story["id"]}
              phx-confirm={"Delete #{@story["id"]}? This cannot be undone."}
              class="text-xs text-error"
            >
              Delete Story
            </button>
          </li>
          <%= if @show_reset do %>
            <li>
              <button
                phx-click="reset_story"
                phx-value-id={@story["id"]}
                phx-confirm={"Reset #{@story["id"]}? This will move it to Draft, clear run data, and remove the worktree."}
                class="text-xs text-warning"
              >
                Reset Story
              </button>
            </li>
            <li><hr class="my-1 border-base-300" /></li>
          <% end %>
          <li class="menu-title px-2 py-1 text-[10px] uppercase tracking-wide text-base-content/50">
            Set Status
          </li>
          <%= if @status_targets == [] do %>
            <li>
              <span class="px-2 py-1 text-xs text-base-content/50">No manual transitions</span>
            </li>
          <% end %>
          <%= for status <- @status_targets do %>
            <li>
              <button
                phx-click="update_story_status"
                phx-value-id={@story["id"]}
                phx-value-status={status}
                class="text-xs"
              >
                {display_status(status)}
              </button>
            </li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  defp build_story_groups(stories) when is_list(stories) do
    grouped = Enum.group_by(stories, &normalize_status(&1["status"]))

    Enum.into(@story_status_columns, %{}, fn {status, _label} ->
      {status, Map.get(grouped, status, [])}
    end)
  end

  defp build_story_groups(_stories), do: build_story_groups([])

  attr :mode, :atom, default: nil
  attr :values, :map, default: %{}
  attr :error, :string, default: nil

  defp story_editor_modal(assigns) do
    show = assigns.mode in [:new, :edit]
    status_options = story_form_status_options(assigns.mode, assigns.values)

    assigns =
      assigns
      |> assign(:show, show)
      |> assign(:status_options, status_options)

    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 z-[60] bg-black/50" phx-click="cancel_story_form" />
      <div class="fixed inset-0 z-[70] flex items-start justify-center overflow-y-auto p-4 sm:p-6">
        <div class="w-full max-w-2xl card bg-base-100 border border-base-300 shadow-2xl my-8">
          <div class="card-body p-4 sm:p-6">
            <div class="flex items-center justify-between gap-3 mb-2">
              <h3 class="text-lg font-semibold">
                <%= if @mode == :new do %>
                  Add Story
                <% else %>
                  Edit Story
                <% end %>
              </h3>
              <button
                type="button"
                phx-click="cancel_story_form"
                class="btn btn-ghost btn-sm btn-circle"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <%= if @error do %>
              <div class="alert alert-error mb-4">
                <span>{@error}</span>
              </div>
            <% end %>

            <form id="story-editor-form" phx-submit="save_story" class="space-y-4">
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <div>
                  <label class="label py-1"><span class="label-text text-sm">Story ID</span></label>
                  <input
                    type="text"
                    name="story[id]"
                    value={Map.get(@values, "id", "")}
                    class="input input-bordered input-sm w-full"
                    readonly={@mode != :new}
                  />
                </div>
                <div>
                  <label class="label py-1"><span class="label-text text-sm">Status</span></label>
                  <select name="story[status]" class="select select-bordered select-sm w-full">
                    <%= for status <- @status_options do %>
                      <option value={status} selected={Map.get(@values, "status", "") == status}>
                        {display_status(status)}
                      </option>
                    <% end %>
                  </select>
                </div>
                <div>
                  <label class="label py-1"><span class="label-text text-sm">Priority</span></label>
                  <input
                    type="number"
                    min="1"
                    name="story[priority]"
                    value={Map.get(@values, "priority", "")}
                    class="input input-bordered input-sm w-full"
                  />
                </div>
              </div>

              <div>
                <label class="label py-1"><span class="label-text text-sm">Title</span></label>
                <input
                  type="text"
                  name="story[title]"
                  value={Map.get(@values, "title", "")}
                  class="input input-bordered input-sm w-full"
                  required
                />
              </div>

              <div>
                <label class="label py-1">
                  <span class="label-text text-sm">Depends On (comma-separated IDs)</span>
                </label>
                <input
                  type="text"
                  name="story[dependsOn]"
                  value={Map.get(@values, "dependsOn", "")}
                  class="input input-bordered input-sm w-full"
                />
              </div>

              <div>
                <label class="label py-1">
                  <span class="label-text text-sm">Acceptance Criteria</span>
                </label>
                <textarea
                  name="story[acceptanceCriteria]"
                  rows="4"
                  class="textarea textarea-bordered w-full text-sm"
                >{Map.get(@values, "acceptanceCriteria", "")}</textarea>
              </div>

              <div>
                <label class="label py-1"><span class="label-text text-sm">Description</span></label>
                <textarea
                  name="story[description]"
                  rows="5"
                  class="textarea textarea-bordered w-full text-sm"
                >{Map.get(@values, "description", "")}</textarea>
              </div>

              <div>
                <label class="label py-1"><span class="label-text text-sm">Notes</span></label>
                <textarea
                  name="story[notes]"
                  rows="3"
                  class="textarea textarea-bordered w-full text-sm"
                >{Map.get(@values, "notes", "")}</textarea>
              </div>

              <div class="flex items-center justify-end gap-2 pt-2">
                <button type="button" phx-click="cancel_story_form" class="btn btn-ghost btn-sm">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">Save Story</button>
              </div>
            </form>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # -- Runs Section --

  attr :run_attempts, :list, required: true
  attr :project, Project, required: true
  attr :stories, :list, default: []

  defp runs_section(assigns) do
    # Fall back to tracker run metadata when no run logs are available yet.
    story_runs =
      assigns.stories
      |> Enum.map(fn story -> %{story: story, run_attempt: story_tracker_run_attempt(story)} end)
      |> Enum.filter(&(&1.run_attempt != nil))

    assigns = assign(assigns, :story_runs, story_runs)

    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Runs</h2>

      <%= if @run_attempts == [] && @story_runs == [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-play" class="size-12 text-base-content/20 mb-2" />
            <p class="text-base-content/60">
              No runs found. Runs appear here when the orchestrator dispatches stories.
            </p>
          </div>
        </div>
      <% end %>
      <%= if @run_attempts != [] do %>
        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Story</th>
                <th>Run #</th>
                <th>Status</th>
                <th>Started</th>
                <th>Ended</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for run <- @run_attempts do %>
                <tr>
                  <td class="font-mono text-sm font-semibold">{run.story_id}</td>
                  <td>{run_number(run.attempt)}</td>
                  <td><.run_status_badge status={run.status} /></td>
                  <td class="text-sm text-base-content/70" title={format_time_tooltip(run.started_at)}>
                    {format_relative_time(run.started_at)}
                  </td>
                  <td class="text-sm text-base-content/70" title={format_time_tooltip(run.ended_at)}>
                    {format_relative_time(run.ended_at)}
                  </td>
                  <td>
                    <.link
                      navigate={~p"/projects/#{@project.slug}/runs/#{run.story_id}/#{run.attempt}"}
                      class="btn btn-ghost btn-xs"
                    >
                      View →
                    </.link>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% end %>
      <%= if @run_attempts == [] && @story_runs != [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-0">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>Story</th>
                  <th>Status</th>
                  <th>Run #</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for story_run <- @story_runs do %>
                  <% story = story_run.story %>
                  <tr id={"run-row-#{story["id"]}"}>
                    <td>
                      <div class="flex items-center gap-2">
                        <span class="font-mono text-xs text-base-content/60">{story["id"]}</span>
                        <span class="text-sm truncate max-w-xs">{story["title"]}</span>
                      </div>
                    </td>
                    <td>
                      <.status_badge status={story["status"] || "open"} />
                    </td>
                    <td class="text-sm text-base-content/60">{run_number(story_run.run_attempt)}</td>
                    <td>
                      <.link
                        navigate={
                          ~p"/projects/#{@project.slug}/runs/#{story["id"]}/#{story_run.run_attempt}"
                        }
                        class="btn btn-xs btn-outline"
                      >
                        View
                      </.link>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Run Detail Section --

  attr :run_detail, :map, default: nil
  attr :story_id, :string, default: nil
  attr :attempt, :string, default: nil
  attr :active_log_tab, :string, default: "agent"
  attr :project, Project, required: true

  defp run_detail_section(assigns) do
    ~H"""
    <div class="flex flex-col gap-4 h-full">
      <div class="flex items-center gap-4">
        <.link
          navigate={~p"/projects/#{@project.slug}/stories/#{@story_id}?tab=runs"}
          class="btn btn-ghost btn-sm gap-2"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Back to Runs
        </.link>
        <span class="badge badge-outline font-mono text-sm">{@story_id}</span>
        <%= if @run_detail do %>
          <.run_status_badge status={@run_detail["metadata"]["status"] || "unknown"} />
        <% end %>
      </div>

      <%= if @run_detail do %>
        <div class="flex gap-0 border-b border-base-300">
          <%= for {tab, label} <- [
            {"agent", "Agent"},
            {"review_agent", "Review Agent"},
            {"worker", "Worker"}
          ] do %>
            <button
              phx-click="set_log_tab"
              phx-value-tab={tab}
              class={[
                "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
                @active_log_tab == tab && "border-primary text-primary",
                @active_log_tab != tab &&
                  "border-transparent text-base-content/60 hover:text-base-content"
              ]}
            >
              {label}
            </button>
          <% end %>
        </div>

        <%= if @run_detail["active_log_content"] do %>
          <pre
            id="log-output"
            phx-hook=".LogScroll"
            class="font-mono text-xs leading-relaxed bg-base-300 p-4 rounded-lg overflow-auto max-h-[75vh] whitespace-pre-wrap"
          ><.ansi_log content={@run_detail["active_log_content"]} /></pre>
        <% else %>
          <p class="text-base-content/50 text-sm italic">No output yet.</p>
        <% end %>
      <% else %>
        <p class="text-base-content/50 text-sm italic">No run logs found for this story.</p>
      <% end %>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LogScroll">
      export default {
        updated() {
          this.el.scrollTop = this.el.scrollHeight
        }
      }
    </script>
    """
  end

  # -- Story Detail Section --

  attr :story, :map, default: nil
  attr :story_id, :string, default: nil
  attr :run_detail, :map, default: nil
  attr :active_log_tab, :string, default: "agent"
  attr :story_detail_tab, :string, default: "details"
  attr :project, Project, required: true
  attr :story_attempts, :list, default: []
  attr :selected_attempt, :string, default: nil

  defp story_detail_section(assigns) do
    assigns = assign(assigns, :editable, local_provider?(assigns.project))

    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex flex-wrap items-center gap-3">
          <.link navigate={~p"/projects/#{@project.slug}/stories"} class="btn btn-ghost btn-sm gap-2">
            <.icon name="hero-arrow-left" class="size-4" /> Back to Stories
          </.link>
          <span class="badge badge-outline font-mono text-sm">{@story_id}</span>
          <%= if @story do %>
            <.status_badge status={@story["status"] || "open"} />
          <% end %>
        </div>

        <%= if @editable && @story do %>
          <% story_id = @story["id"] || @story_id %>
          <% status_targets = manual_status_targets(@story["status"]) %>
          <div class="dropdown dropdown-end">
            <label tabindex="0" class="btn btn-ghost btn-sm gap-2">
              Actions <.icon name="hero-chevron-down" class="size-4" />
            </label>
            <ul
              tabindex="0"
              class="dropdown-content menu menu-xs bg-base-100 rounded-box shadow-lg border border-base-300 z-50 w-44 p-1"
            >
              <li>
                <button phx-click="open_edit_story_form" phx-value-id={story_id} class="text-xs">
                  Edit Story
                </button>
              </li>
              <li>
                <button
                  phx-click="delete_story"
                  phx-value-id={story_id}
                  phx-confirm={"Delete #{story_id}? This cannot be undone."}
                  class="text-xs text-error"
                >
                  Delete Story
                </button>
              </li>
              <%= if normalize_status(@story["status"]) != "open" do %>
                <li>
                  <button
                    phx-click="reset_story"
                    phx-value-id={story_id}
                    phx-confirm={"Reset #{story_id}? This will move it to Draft, clear run data, and remove the worktree."}
                    class="text-xs text-warning"
                  >
                    Reset Story
                  </button>
                </li>
                <li><hr class="my-1 border-base-300" /></li>
              <% end %>
              <li class="menu-title px-2 py-1 text-[10px] tracking-wide uppercase text-base-content/50">
                Set Status
              </li>
              <%= if status_targets == [] do %>
                <li>
                  <span class="px-2 py-1 text-xs text-base-content/50">
                    No manual transitions
                  </span>
                </li>
              <% end %>
              <%= for s <- status_targets do %>
                <li>
                  <button
                    phx-click="update_story_status"
                    phx-value-id={story_id}
                    phx-value-status={s}
                    class="text-xs"
                  >
                    {display_status(s)}
                  </button>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>

      <%= if @story do %>
        <h1 class="text-2xl font-bold">{@story["title"]}</h1>
      <% end %>

      <div class="flex gap-0 border-b border-base-300">
        <button
          phx-click="set_story_tab"
          phx-value-tab="details"
          class={[
            "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            @story_detail_tab == "details" && "border-primary text-primary",
            @story_detail_tab != "details" &&
              "border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          Details
        </button>
        <button
          phx-click="set_story_tab"
          phx-value-tab="runs"
          class={[
            "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            @story_detail_tab == "runs" && "border-primary text-primary",
            @story_detail_tab != "runs" &&
              "border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          Runs
        </button>
      </div>

      <%= if @story_detail_tab == "details" do %>
        <%= if @story do %>
          <div class="space-y-4">
            <%= if @story["description"] do %>
              <div>
                <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Description
                </h3>
                <div class="prose prose-sm max-w-none">
                  {raw(markdown_to_html(@story["description"]))}
                </div>
              </div>
            <% end %>

            <%= if criteria = @story["acceptanceCriteria"] do %>
              <%= if present?(criteria) do %>
                <div>
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Acceptance Criteria
                  </h3>

                  <%= if is_list(criteria) do %>
                    <ul class="list-disc list-inside space-y-1">
                      <%= for criterion <- criteria do %>
                        <li class="text-sm">{criterion}</li>
                      <% end %>
                    </ul>
                  <% else %>
                    <div class="prose prose-sm max-w-none">
                      {raw(markdown_to_html(criteria))}
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>

            <%= if @story["notes"] do %>
              <div>
                <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Notes
                </h3>
                <div class="prose prose-sm max-w-none text-base-content/70">
                  {raw(markdown_to_html(@story["notes"]))}
                </div>
              </div>
            <% end %>

            <%= if depends_on = @story["dependsOn"] do %>
              <%= if depends_on != [] do %>
                <div>
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Depends On
                  </h3>
                  <div class="flex flex-wrap gap-2">
                    <%= for dep <- depends_on do %>
                      <span class="badge badge-outline font-mono text-xs">{dep}</span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>

            <%= if @story["priority"] do %>
              <div>
                <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Priority
                </h3>
                <span class="text-sm capitalize">{@story["priority"]}</span>
              </div>
            <% end %>

            <%= if @story["lastError"] do %>
              <div>
                <h3 class="text-xs font-semibold text-error uppercase tracking-wide mb-2">
                  Last Error
                </h3>
                <p class="text-sm text-error bg-error/10 p-3 rounded-lg">
                  {@story["lastError"]}
                </p>
              </div>
            <% end %>
          </div>
        <% else %>
          <p class="text-base-content/50 text-sm italic">Story not found.</p>
        <% end %>
      <% end %>

      <%= if @story_detail_tab == "runs" do %>
        <div class="flex flex-col gap-4">
          <%= if @selected_attempt do %>
            <div class="flex items-center gap-3">
              <.link
                navigate={~p"/projects/#{@project.slug}/stories/#{@story_id}?tab=runs"}
                class="btn btn-ghost btn-sm gap-2"
              >
                <.icon name="hero-arrow-left" class="size-4" /> All Runs
              </.link>
              <span class="text-sm text-base-content/60">Run {run_number(@selected_attempt)}</span>
            </div>

            <div class="flex gap-0 border-b border-base-300">
              <%= for {tab, label} <- [
                {"agent", "Agent"},
                {"review_agent", "Review Agent"},
                {"worker", "Worker"}
              ] do %>
                <button
                  phx-click="set_log_tab"
                  phx-value-tab={tab}
                  class={[
                    "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
                    @active_log_tab == tab && "border-primary text-primary",
                    @active_log_tab != tab &&
                      "border-transparent text-base-content/60 hover:text-base-content"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <%= if @run_detail && @run_detail["active_log_content"] do %>
              <pre
                id="log-output"
                phx-hook=".LogScroll"
                class="font-mono text-xs leading-relaxed bg-base-300 p-4 rounded-lg overflow-auto max-h-[75vh] whitespace-pre-wrap"
              ><.ansi_log content={@run_detail["active_log_content"]} /></pre>
            <% else %>
              <p class="text-base-content/50 text-sm italic">No output yet.</p>
            <% end %>
          <% else %>
            <%= if @story_attempts == [] do %>
              <p class="text-base-content/50 text-sm italic">No runs yet for this story.</p>
            <% else %>
              <div class="card bg-base-200 border border-base-300">
                <div class="overflow-x-auto">
                  <table class="table table-sm">
                    <thead>
                      <tr>
                        <th>Run #</th>
                        <th>Status</th>
                        <th>Started</th>
                        <th>Duration</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for run <- @story_attempts do %>
                        <tr class="hover cursor-pointer">
                          <td>
                            <.link
                              navigate={
                                ~p"/projects/#{@project.slug}/runs/#{@story_id}/#{run.attempt}"
                              }
                              class="font-mono text-sm hover:text-primary"
                            >
                              {run_number(run.attempt)}
                            </.link>
                          </td>
                          <td><.run_status_badge status={run.status} /></td>
                          <td class="text-xs text-base-content/60">
                            {format_time(run.started_at)}
                          </td>
                          <td class="text-xs text-base-content/60">
                            {format_duration(run.started_at, run.ended_at)}
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Settings Section --

  attr :project, Project, required: true
  attr :workflow, :map, required: true
  attr :workflow_editable, :boolean, default: false

  defp settings_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Project Settings</h2>

      <%!-- Project info --%>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body">
          <div class="grid sm:grid-cols-2 gap-4">
            <div>
              <span class="text-sm text-base-content/60">Name</span>
              <p class="font-medium">{@project.name}</p>
            </div>
            <div>
              <span class="text-sm text-base-content/60">Slug</span>
              <p class="font-medium font-mono">{@project.slug}</p>
            </div>
            <div>
              <span class="text-sm text-base-content/60">Provider</span>
              <p class="font-medium capitalize">{@project.provider}</p>
            </div>
            <div>
              <span class="text-sm text-base-content/60">Default Branch</span>
              <p class="font-medium">{@project.default_branch}</p>
            </div>
            <%= if @project.local_path do %>
              <div class="sm:col-span-2">
                <span class="text-sm text-base-content/60">Local Path</span>
                <p class="font-medium font-mono text-sm break-all">
                  {@project.local_path}
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%= if @workflow.path do %>
        <%!-- Workflow settings form --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body gap-4">
            <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-1">
              <h3 class="card-title text-lg shrink-0">WORKFLOW.md</h3>
              <span class="font-mono text-xs text-base-content/50 break-all">
                {@workflow.path}
              </span>
            </div>

            <%= if @workflow.error do %>
              <div class="alert alert-error text-sm">{@workflow.error}</div>
            <% end %>

            <form phx-submit="save_settings" class="space-y-6">
              <%!-- Workspace --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Workspace
                </p>
                <div class="grid sm:grid-cols-2 gap-4">
                  <div class="sm:col-span-2">
                    <span class="text-xs text-base-content/50">Workspaces directory</span>
                    <p class="font-mono text-sm mt-0.5 text-base-content/70 break-all">
                      {Kollywood.ServiceConfig.project_workspace_root(@project.slug)}/<em class="not-italic text-base-content/40">issue-id</em>
                    </p>
                    <p class="text-xs text-base-content/40 mt-1">
                      Configured via
                      <code class="font-mono bg-base-100 px-1 rounded">KOLLYWOOD_HOME</code>
                      (default: <code class="font-mono bg-base-100 px-1 rounded">~/.kollywood</code>)
                    </p>
                  </div>
                  <div class="min-w-0">
                    <label class="label pb-1"><span class="label-text text-sm">Strategy</span></label>
                    <select
                      name="settings[workspace][strategy]"
                      class="select select-bordered select-sm w-full max-w-full"
                    >
                      <%= for s <- ["clone", "worktree"] do %>
                        <option
                          value={s}
                          selected={get_in(@workflow.parsed, ["workspace", "strategy"]) == s}
                        >
                          {s}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Agent --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Agent
                </p>
                <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
                  <div>
                    <label class="label pb-1"><span class="label-text text-sm">Kind</span></label>
                    <select
                      name="settings[agent][kind]"
                      class="select select-bordered select-sm w-full"
                    >
                      <%= for k <- ["amp", "claude", "cursor", "opencode", "pi"] do %>
                        <option value={k} selected={get_in(@workflow.parsed, ["agent", "kind"]) == k}>
                          {k}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Max Turns</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      name="settings[agent][max_turns]"
                      value={get_in(@workflow.parsed, ["agent", "max_turns"]) || 20}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Timeout (ms)</span>
                    </label>
                    <input
                      type="number"
                      min="1000"
                      step="1000"
                      name="settings[agent][timeout_ms]"
                      value={get_in(@workflow.parsed, ["agent", "timeout_ms"]) || 7_200_000}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div class="sm:col-span-2 lg:col-span-3">
                    <label class="label pb-1">
                      <span class="label-text text-sm">
                        Custom command
                        <span class="text-base-content/40 text-xs">(optional override)</span>
                      </span>
                    </label>
                    <input
                      type="text"
                      name="settings[agent][command]"
                      value={get_in(@workflow.parsed, ["agent", "command"]) || ""}
                      placeholder="e.g. /usr/local/bin/amp"
                      class="input input-bordered input-sm w-full font-mono"
                    />
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Quality --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Quality
                </p>
                <div class="grid sm:grid-cols-2 gap-4 mb-4">
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Max Cycles</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="10"
                      name="settings[quality][max_cycles]"
                      value={get_in(@workflow.parsed, ["quality", "max_cycles"]) || 1}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                </div>

                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Checks
                </p>
                <div class="space-y-4">
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Required checks</span>
                      <span class="label-text-alt text-base-content/40">one per line</span>
                    </label>
                    <textarea
                      name="settings[quality][checks][required]"
                      rows="4"
                      spellcheck="false"
                      class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
                    >{(get_in(@workflow.parsed, ["quality", "checks", "required"]) || []) |> Enum.join("\n")}</textarea>
                  </div>
                  <div class="grid sm:grid-cols-3 gap-4">
                    <div>
                      <label class="label pb-1">
                        <span class="label-text text-sm">Max Cycles</span>
                      </label>
                      <input
                        type="number"
                        min="1"
                        max="10"
                        name="settings[quality][checks][max_cycles]"
                        value={
                          get_in(@workflow.parsed, ["quality", "checks", "max_cycles"]) ||
                            get_in(@workflow.parsed, ["quality", "max_cycles"]) || 1
                        }
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <div>
                      <label class="label pb-1">
                        <span class="label-text text-sm">Timeout (ms)</span>
                      </label>
                      <input
                        type="number"
                        min="1000"
                        step="1000"
                        name="settings[quality][checks][timeout_ms]"
                        value={
                          get_in(@workflow.parsed, ["quality", "checks", "timeout_ms"]) ||
                            7_200_000
                        }
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <div class="flex items-center gap-2 pt-5">
                      <input
                        type="hidden"
                        name="settings[quality][checks][fail_fast]"
                        value="false"
                      />
                      <input
                        type="checkbox"
                        name="settings[quality][checks][fail_fast]"
                        value="true"
                        checked={
                          get_in(@workflow.parsed, ["quality", "checks", "fail_fast"]) != false
                        }
                        class="toggle toggle-sm"
                      />
                      <span class="text-sm">Fail fast</span>
                    </div>
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Review --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Review
                </p>
                <div class="grid sm:grid-cols-2 gap-4">
                  <div class="sm:col-span-2 flex items-center gap-2">
                    <input type="hidden" name="settings[quality][review][enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[quality][review][enabled]"
                      value="true"
                      checked={get_in(@workflow.parsed, ["quality", "review", "enabled"]) == true}
                      class="toggle toggle-sm toggle-primary"
                    />
                    <span class="text-sm">Enable review</span>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Max Cycles</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="10"
                      name="settings[quality][review][max_cycles]"
                      value={
                        get_in(@workflow.parsed, ["quality", "review", "max_cycles"]) ||
                          get_in(@workflow.parsed, ["quality", "max_cycles"]) || 1
                      }
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                  <div></div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Pass Token</span>
                    </label>
                    <input
                      type="text"
                      name="settings[quality][review][pass_token]"
                      value={
                        get_in(@workflow.parsed, ["quality", "review", "pass_token"]) ||
                          "REVIEW_PASS"
                      }
                      class="input input-bordered input-sm w-full font-mono"
                    />
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Fail Token</span>
                    </label>
                    <input
                      type="text"
                      name="settings[quality][review][fail_token]"
                      value={
                        get_in(@workflow.parsed, ["quality", "review", "fail_token"]) ||
                          "REVIEW_FAIL"
                      }
                      class="input input-bordered input-sm w-full font-mono"
                    />
                  </div>

                  <%!-- Reviewer Agent --%>
                  <div class="sm:col-span-2 pt-2">
                    <p class="text-xs font-medium text-base-content/50 mb-3">
                      Reviewer Agent
                    </p>
                    <div class="space-y-4">
                      <div class="flex items-center gap-2">
                        <input
                          type="hidden"
                          name="settings[quality][review][agent_custom]"
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name="settings[quality][review][agent_custom]"
                          value="true"
                          checked={get_in(@workflow.parsed, ["quality", "review", "agent"]) != nil}
                          class="toggle toggle-sm"
                        />
                        <span class="text-sm">Use a different agent for reviews</span>
                      </div>
                      <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
                        <div>
                          <label class="label pb-1">
                            <span class="label-text text-sm">Kind</span>
                          </label>
                          <select
                            name="settings[quality][review][agent][kind]"
                            class="select select-bordered select-sm w-full"
                          >
                            <%= for k <- ["amp", "claude", "cursor", "opencode", "pi"] do %>
                              <option
                                value={k}
                                selected={
                                  (get_in(@workflow.parsed, ["quality", "review", "agent", "kind"]) ||
                                     get_in(@workflow.parsed, ["agent", "kind"])) == k
                                }
                              >
                                {k}
                              </option>
                            <% end %>
                          </select>
                        </div>
                        <div>
                          <label class="label pb-1">
                            <span class="label-text text-sm">Timeout (ms)</span>
                          </label>
                          <input
                            type="number"
                            min="1000"
                            step="1000"
                            name="settings[quality][review][agent][timeout_ms]"
                            value={
                              get_in(@workflow.parsed, ["quality", "review", "agent", "timeout_ms"]) ||
                                7_200_000
                            }
                            class="input input-bordered input-sm w-full"
                          />
                        </div>
                        <div class="sm:col-span-2 lg:col-span-3">
                          <label class="label pb-1">
                            <span class="label-text text-sm">
                              Custom command
                              <span class="text-base-content/40 text-xs">(optional override)</span>
                            </span>
                          </label>
                          <input
                            type="text"
                            name="settings[quality][review][agent][command]"
                            value={
                              get_in(@workflow.parsed, ["quality", "review", "agent", "command"]) ||
                                ""
                            }
                            placeholder="e.g. /usr/local/bin/amp"
                            class="input input-bordered input-sm w-full font-mono"
                          />
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Publish --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Publish
                </p>
                <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
                  <div>
                    <label class="label pb-1"><span class="label-text text-sm">Provider</span></label>
                    <select
                      name="settings[publish][provider]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option
                        value=""
                        selected={is_nil(get_in(@workflow.parsed, ["publish", "provider"]))}
                      >
                        Auto (from project)
                      </option>
                      <%= for v <- ["github", "gitlab"] do %>
                        <option
                          value={v}
                          selected={get_in(@workflow.parsed, ["publish", "provider"]) == v}
                        >
                          {v}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Mode</span>
                    </label>
                    <select
                      name="settings[publish][mode]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option
                        value=""
                        selected={
                          is_nil(get_in(@workflow.parsed, ["publish", "mode"])) or
                            get_in(@workflow.parsed, ["publish", "mode"]) == ""
                        }
                      >
                        Auto (from provider)
                      </option>
                      <%= for v <- ["push", "pr", "auto_merge"] do %>
                        <option
                          value={v}
                          selected={to_string(get_in(@workflow.parsed, ["publish", "mode"])) == v}
                        >
                          {v}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">PR Type</span>
                    </label>
                    <select
                      name="settings[publish][pr_type]"
                      class="select select-bordered select-sm w-full"
                    >
                      <%= for v <- ["ready", "draft"] do %>
                        <option
                          value={v}
                          selected={
                            if(
                              to_string(get_in(@workflow.parsed, ["publish", "auto_create_pr"])) ==
                                "draft",
                              do: v == "draft",
                              else: v == "ready"
                            )
                          }
                        >
                          {v}
                        </option>
                      <% end %>
                    </select>
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Git --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Git
                </p>
                <div class="grid sm:grid-cols-2 gap-4">
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Base Branch</span>
                    </label>
                    <input
                      type="text"
                      name="settings[git][base_branch]"
                      value={get_in(@workflow.parsed, ["git", "base_branch"]) || "main"}
                      class="input input-bordered input-sm w-full font-mono"
                    />
                  </div>
                  <div></div>
                </div>
              </div>

              <div class="pt-2 flex justify-end">
                <button type="submit" class="btn btn-primary btn-sm">Save Settings</button>
              </div>
            </form>
          </div>
        </div>

        <%!-- Prompt template editor --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body gap-4">
            <h3 class="card-title text-lg">Prompt Template</h3>
            <%= if @workflow_editable do %>
              <form phx-submit="save_workflow" class="space-y-3">
                <textarea
                  name="body"
                  rows="16"
                  spellcheck="false"
                  class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed bg-base-100"
                >{@workflow.body}</textarea>
                <div class="flex justify-end">
                  <button type="submit" class="btn btn-primary btn-sm">Save Template</button>
                </div>
              </form>
            <% else %>
              <textarea
                rows="16"
                spellcheck="false"
                disabled
                class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed bg-base-100"
              >{@workflow.body}</textarea>
              <p class="text-xs text-base-content/60">
                Edit .kollywood/WORKFLOW.md in your repository to change these settings.
              </p>
            <% end %>
          </div>
        </div>

        <%!-- Review template editor --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body gap-4">
            <div class="flex items-start justify-between gap-4">
              <div>
                <h3 class="card-title text-lg">Review Prompt Template</h3>
                <p class="text-sm text-base-content/60 mt-1">
                  Template used to prompt the reviewer agent. Saved as
                  <code class="font-mono text-xs bg-base-100 px-1 rounded">
                    quality.review.prompt_template
                  </code>
                  in WORKFLOW.md.
                </p>
              </div>
              <%= if @workflow.review_template_is_default do %>
                <span class="badge badge-ghost badge-sm shrink-0 mt-1">default</span>
              <% else %>
                <span class="badge badge-primary badge-sm shrink-0 mt-1">custom</span>
              <% end %>
            </div>

            <%= if @workflow_editable do %>
              <form phx-submit="save_review_template" class="space-y-4">
                <textarea
                  name="review_template"
                  rows="20"
                  spellcheck="false"
                  class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed bg-base-100"
                >{@workflow.review_template}</textarea>
                <div class="flex items-center justify-between">
                  <%= if @workflow.review_template_is_default do %>
                    <p class="text-xs text-base-content/50">
                      Showing built-in default. Edit and save to override for this project.
                    </p>
                  <% else %>
                    <p class="text-xs text-base-content/50">
                      Custom template active for this project.
                    </p>
                  <% end %>
                  <button type="submit" class="btn btn-primary btn-sm">Save Review Template</button>
                </div>
              </form>
            <% else %>
              <textarea
                rows="20"
                spellcheck="false"
                disabled
                class="textarea textarea-bordered w-full font-mono text-xs leading-relaxed bg-base-100"
              >{@workflow.review_template}</textarea>
              <p class="text-xs text-base-content/60">
                Edit .kollywood/WORKFLOW.md in your repository to change these settings.
              </p>
            <% end %>
          </div>
        </div>
      <% else %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-document-text" class="size-12 text-base-content/20 mb-2" />
            <p class="text-base-content/60">No WORKFLOW.md found for this project.</p>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Small Components --

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, default: "neutral"

  defp stat_card(assigns) do
    ~H"""
    <div class="stat bg-base-200 border border-base-300 rounded-box">
      <div class="stat-title">{@title}</div>
      <div class={"stat-value text-#{@color}"}>{@value}</div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    color =
      case normalize_status(assigns.status) do
        "open" -> "badge-info"
        "in_progress" -> "badge-warning"
        "done" -> "badge-success"
        "failed" -> "badge-error"
        "cancelled" -> "badge-ghost"
        "draft" -> "badge-ghost badge-outline"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>{display_status(@status)}</span>
    """
  end

  attr :status, :string, required: true

  defp run_status_badge(assigns) do
    {color, label} =
      case assigns.status do
        "running" -> {"badge-warning", "Running"}
        "ok" -> {"badge-success", "Passed"}
        "finished" -> {"badge-success", "Done"}
        "failed" -> {"badge-error", "Failed"}
        "stopped" -> {"badge-ghost", "Stopped"}
        other -> {"badge-ghost", other}
      end

    assigns = assigns |> assign(:color, color) |> assign(:label, label)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>{@label}</span>
    """
  end

  # -- Orchestrator Status Components --

  attr :status, :map, default: nil

  defp orchestrator_indicator(assigns) do
    ~H"""
    <%= if @status do %>
      <div
        class="flex items-center gap-1.5 text-xs text-base-content/50"
        title={"Last polled: #{time_ago(@status.last_poll_at)}"}
      >
        <span class={[
          "size-2 rounded-full",
          @status.running_count > 0 && "bg-success animate-pulse",
          @status.running_count == 0 && @status.last_error == nil && "bg-base-content/30",
          @status.last_error != nil && "bg-error"
        ]}>
        </span>
        <%= if @status.running_count > 0 do %>
          <span class="hidden sm:inline">{@status.running_count} running</span>
        <% else %>
          <span class="hidden sm:inline">{time_ago(@status.last_poll_at)}</span>
        <% end %>
      </div>
    <% end %>
    """
  end

  attr :status, :map, default: nil

  defp orchestrator_status_bar(assigns) do
    ~H"""
    <%= if @status do %>
      <div class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-xs border",
        @status.running_count > 0 && "bg-success/10 border-success/20 text-success-content",
        @status.running_count == 0 && @status.last_error == nil &&
          "bg-base-200 border-base-300 text-base-content/60",
        @status.last_error != nil && "bg-error/10 border-error/20 text-error"
      ]}>
        <span class={[
          "size-2 rounded-full shrink-0",
          @status.running_count > 0 && "bg-success animate-pulse",
          @status.running_count == 0 && @status.last_error == nil && "bg-base-content/30",
          @status.last_error != nil && "bg-error"
        ]}>
        </span>

        <%= if @status.running_count > 0 do %>
          <span class="font-medium">Running</span>
          <span class="text-base-content/50">·</span>
          <%= for run <- @status.running do %>
            <span class="font-mono">{run.identifier}</span>
          <% end %>
          <span class="text-base-content/50">·</span>
          <span>polled {time_ago(@status.last_poll_at)}</span>
        <% else %>
          <%= if @status.last_error do %>
            <span class="font-medium">Poll error:</span>
            <span class="truncate max-w-md">{@status.last_error}</span>
          <% else %>
            <span>Idle · polled {time_ago(@status.last_poll_at)}</span>
          <% end %>
        <% end %>
      </div>
    <% end %>
    """
  end

  # -- Story Form / Local Tracker Helpers --

  defp local_tracker_path(%Project{provider: :local, tracker_path: path}) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        {:error, "This project does not have a tracker path configured."}

      true ->
        {:ok, path}
    end
  end

  defp local_tracker_path(%Project{}),
    do: {:error, "Story editing is only available for local tracker projects."}

  defp local_tracker_path(_project), do: {:error, "No project selected."}

  defp default_story_form_values(stories) when is_list(stories) do
    %{
      "id" => suggested_story_id(stories),
      "title" => "",
      "description" => "",
      "acceptanceCriteria" => "",
      "priority" => to_string(next_story_priority(stories)),
      "status" => "draft",
      "dependsOn" => "",
      "notes" => ""
    }
  end

  defp default_story_form_values(_stories), do: default_story_form_values([])

  defp story_to_form_values(story) when is_map(story) do
    %{
      "id" => to_string(Map.get(story, "id", "")),
      "title" => to_string(Map.get(story, "title", "")),
      "description" => to_string(Map.get(story, "description", "")),
      "acceptanceCriteria" => acceptance_criteria_text(Map.get(story, "acceptanceCriteria")),
      "priority" => to_string(Map.get(story, "priority", "")),
      "status" => normalize_status(Map.get(story, "status", "open")),
      "dependsOn" => depends_on_text(Map.get(story, "dependsOn")),
      "notes" => to_string(Map.get(story, "notes", ""))
    }
  end

  defp story_to_form_values(_story), do: default_story_form_values([])

  defp normalize_story_form_params(params) when is_map(params) do
    %{
      "id" => Map.get(params, "id"),
      "title" => Map.get(params, "title"),
      "description" => Map.get(params, "description"),
      "acceptanceCriteria" => Map.get(params, "acceptanceCriteria"),
      "priority" => Map.get(params, "priority"),
      "status" => Map.get(params, "status"),
      "dependsOn" => Map.get(params, "dependsOn"),
      "notes" => Map.get(params, "notes")
    }
  end

  defp normalize_story_form_params(_params), do: %{}

  defp merge_story_form_values(existing, attrs)
       when is_map(existing) and is_map(attrs) do
    existing
    |> Map.merge(
      Map.take(attrs, [
        "id",
        "title",
        "description",
        "acceptanceCriteria",
        "priority",
        "status",
        "dependsOn",
        "notes"
      ])
    )
  end

  defp merge_story_form_values(_existing, attrs) when is_map(attrs), do: attrs
  defp merge_story_form_values(existing, _attrs) when is_map(existing), do: existing
  defp merge_story_form_values(_existing, _attrs), do: %{}

  defp clear_story_form(socket) do
    socket
    |> assign(:story_form_mode, nil)
    |> assign(:story_form_story_id, nil)
    |> assign(:story_form_values, %{})
    |> assign(:story_form_error, nil)
  end

  defp clear_story_form_if_editing(socket, story_id) when is_binary(story_id) do
    if socket.assigns.story_form_story_id == story_id do
      clear_story_form(socket)
    else
      socket
    end
  end

  defp clear_story_form_if_editing(socket, _story_id), do: socket

  defp sync_story_detail_selection(socket) do
    if socket.assigns[:live_action] == :story_detail do
      story_id = socket.assigns[:run_detail_story_id]
      story = Enum.find(socket.assigns.stories, &(&1["id"] == story_id))
      assign(socket, :selected_story, story)
    else
      socket
    end
  end

  defp story_form_status_options(:new, _values), do: ["draft", "open"]

  defp story_form_status_options(:edit, values) when is_map(values) do
    current = normalize_status(Map.get(values, "status", "open"))
    [current | manual_status_targets(current)] |> Enum.uniq()
  end

  defp story_form_status_options(_mode, _values), do: ["draft", "open"]

  defp manual_status_targets(status) do
    PrdJson.manual_transition_targets(status)
  end

  defp suggested_story_id(stories) when is_list(stories) do
    next_number =
      stories
      |> Enum.map(&Map.get(&1, "id"))
      |> Enum.map(fn
        "US-" <> rest ->
          case Integer.parse(rest) do
            {num, ""} when num > 0 -> num
            _other -> nil
          end

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 0 end)
      |> Kernel.+(1)

    "US-" <> String.pad_leading(Integer.to_string(next_number), 3, "0")
  end

  defp suggested_story_id(_stories), do: "US-001"

  defp next_story_priority(stories) when is_list(stories) do
    stories
    |> Enum.map(fn story -> story["priority"] end)
    |> Enum.map(fn
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {num, ""} when num > 0 -> num
          _other -> nil
        end

      _other ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp next_story_priority(_stories), do: 1

  defp depends_on_text(values) when is_list(values), do: Enum.map_join(values, ", ", &to_string/1)
  defp depends_on_text(_values), do: ""

  defp acceptance_criteria_text(values) when is_list(values),
    do: Enum.map_join(values, "\n", &to_string/1)

  defp acceptance_criteria_text(value) when is_binary(value), do: value
  defp acceptance_criteria_text(_value), do: ""

  # -- Data Loading --

  defp load_project_data(socket, nil) do
    assign(socket,
      stories: [],
      counters: %{open: 0, in_progress: 0, done: 0, failed: 0},
      run_attempts: [],
      recent_runs: [],
      run_detail: nil,
      run_detail_story_id: nil,
      run_detail_attempt: nil
    )
  end

  defp load_project_data(socket, project) do
    stories = read_stories(project)
    counters = count_stories(stories)
    run_attempts = list_run_attempts(project)
    recent_runs = build_recent_runs(run_attempts, stories)

    socket =
      socket
      |> assign(:stories, stories)
      |> assign(:counters, counters)
      |> assign(:run_attempts, run_attempts)
      |> assign(:recent_runs, recent_runs)

    # Load run detail if the action requires it
    story_id = socket.assigns[:run_detail_story_id]
    attempt = socket.assigns[:run_detail_attempt]

    tab = socket.assigns[:active_log_tab] || "agent"

    run_detail =
      cond do
        story_id && attempt -> load_run_detail_for_attempt(project, story_id, attempt, tab)
        story_id -> load_run_detail_latest(project, story_id, tab)
        true -> nil
      end

    assign(socket, :run_detail, run_detail)
  end

  @status_group_order ~w(in_progress open failed done merged draft)

  defp read_stories(project) do
    path = project.tracker_path

    if is_binary(path) and File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content) do
        decoded
        |> Map.get("userStories", [])
        |> sort_stories()
      else
        _ -> []
      end
    else
      []
    end
  end

  defp sort_stories(stories) do
    stories
    |> Enum.with_index()
    |> Enum.sort(fn {story_a, idx_a}, {story_b, idx_b} ->
      group_a = status_group_rank(story_a["status"])
      group_b = status_group_rank(story_b["status"])

      if group_a != group_b do
        group_a < group_b
      else
        ts_a = story_a["completedAt"] || story_a["startedAt"]
        ts_b = story_b["completedAt"] || story_b["startedAt"]

        case {ts_a, ts_b} do
          {nil, nil} -> idx_a <= idx_b
          {nil, _} -> false
          {_, nil} -> true
          {a, b} when a == b -> idx_a <= idx_b
          {a, b} -> a >= b
        end
      end
    end)
    |> Enum.map(fn {story, _idx} -> story end)
  end

  defp status_group_rank(status) do
    normalized = normalize_status(status)
    Enum.find_index(@status_group_order, &(&1 == normalized)) || length(@status_group_order)
  end

  defp count_stories(stories) do
    %{
      open: count_status(stories, "open"),
      in_progress: count_status(stories, "in_progress"),
      done: count_status(stories, "done"),
      failed: count_status(stories, "failed")
    }
  end

  defp count_status(stories, status) do
    Enum.count(stories, &(normalize_status(&1["status"]) == status))
  end

  defp list_run_attempts(project) do
    project
    |> run_logs_dirs()
    |> Enum.flat_map(&list_run_attempts_in_dir/1)
    |> Enum.reduce(%{}, fn run, acc ->
      Map.put_new(acc, {run.story_id, run.attempt}, run)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.started_at, :desc)
  rescue
    _ -> []
  end

  defp list_run_attempts_in_dir(log_root) when is_binary(log_root) do
    if File.dir?(log_root) do
      log_root
      |> File.ls!()
      |> Enum.flat_map(fn story_dir_name ->
        story_dir = Path.join(log_root, story_dir_name)

        if File.dir?(story_dir) do
          story_dir
          |> File.ls!()
          |> Enum.filter(&String.starts_with?(&1, "attempt-"))
          |> Enum.map(fn attempt_dir_name ->
            attempt_num =
              attempt_dir_name |> String.replace_prefix("attempt-", "") |> String.to_integer()

            metadata_path = Path.join([story_dir, attempt_dir_name, "metadata.json"])

            metadata =
              if File.exists?(metadata_path) do
                with {:ok, content} <- File.read(metadata_path),
                     {:ok, decoded} <- Jason.decode(content) do
                  decoded
                else
                  _ -> %{}
                end
              else
                %{}
              end

            %{
              story_id: story_dir_name,
              attempt: attempt_num,
              status: metadata["status"] || "unknown",
              started_at: metadata["started_at"],
              ended_at: metadata["ended_at"],
              error: metadata["error"]
            }
          end)
        else
          []
        end
      end)
    else
      []
    end
  end

  defp list_run_attempts_in_dir(_), do: []

  defp build_recent_runs(run_attempts, stories) do
    title_by_id = Map.new(stories, &{&1["id"], &1["title"]})

    run_attempts
    |> Enum.sort_by(fn r -> r.ended_at || r.started_at || "" end, :desc)
    |> Enum.take(10)
    |> Enum.map(fn r ->
      Map.put(r, :story_title, Map.get(title_by_id, r.story_id, r.story_id))
    end)
  end

  # -- Settings Helpers --

  @workflow_yaml_key_order ~w(tracker workspace agent quality runtime hooks publish git)

  defp apply_settings(parsed, settings) do
    agent_p = Map.get(settings, "agent", %{})
    workspace_p = Map.get(settings, "workspace", %{})
    quality_p = Map.get(settings, "quality", %{})
    checks_p = Map.get(quality_p, "checks", %{})
    review_p = Map.get(quality_p, "review", %{})
    publish_p = Map.get(settings, "publish", %{})
    git_p = Map.get(settings, "git", %{})

    existing_agent = Map.get(parsed, "agent", %{})
    existing_quality = Map.get(parsed, "quality", %{})
    existing_checks = Map.get(existing_quality, "checks", %{})
    existing_review = Map.get(existing_quality, "review", %{})

    command = String.trim(Map.get(agent_p, "command", ""))

    new_agent =
      existing_agent
      |> Map.put("kind", Map.get(agent_p, "kind", Map.get(existing_agent, "kind", "amp")))
      |> Map.put(
        "max_turns",
        parse_form_int(agent_p, "max_turns", Map.get(existing_agent, "max_turns", 20))
      )
      |> Map.put(
        "timeout_ms",
        parse_form_int(agent_p, "timeout_ms", Map.get(existing_agent, "timeout_ms", 7_200_000))
      )
      |> then(fn a ->
        if command != "", do: Map.put(a, "command", command), else: Map.delete(a, "command")
      end)

    checks_required =
      case String.trim(Map.get(checks_p, "required", "")) do
        "" -> []
        raw -> raw |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      end

    quality_max_cycles =
      parse_form_int(quality_p, "max_cycles", Map.get(existing_quality, "max_cycles", 1))

    new_checks = %{
      "required" => checks_required,
      "fail_fast" => Map.get(checks_p, "fail_fast") == "true",
      "max_cycles" =>
        parse_form_int(
          checks_p,
          "max_cycles",
          Map.get(existing_checks, "max_cycles", quality_max_cycles)
        ),
      "timeout_ms" =>
        parse_form_int(checks_p, "timeout_ms", Map.get(existing_checks, "timeout_ms", 7_200_000))
    }

    existing_prompt_template = get_in(parsed, ["quality", "review", "prompt_template"])
    review_agent_custom = Map.get(review_p, "agent_custom") == "true"
    review_agent_p = Map.get(review_p, "agent", %{})

    new_review =
      %{
        "enabled" => Map.get(review_p, "enabled") == "true",
        "max_cycles" =>
          parse_form_int(
            review_p,
            "max_cycles",
            Map.get(existing_review, "max_cycles", quality_max_cycles)
          ),
        "pass_token" =>
          Map.get(review_p, "pass_token", "REVIEW_PASS")
          |> String.trim()
          |> then(&if &1 == "", do: "REVIEW_PASS", else: &1),
        "fail_token" =>
          Map.get(review_p, "fail_token", "REVIEW_FAIL")
          |> String.trim()
          |> then(&if &1 == "", do: "REVIEW_FAIL", else: &1)
      }
      |> then(fn r ->
        if is_binary(existing_prompt_template) and existing_prompt_template != "",
          do: Map.put(r, "prompt_template", existing_prompt_template),
          else: r
      end)
      |> then(fn r ->
        if review_agent_custom do
          review_agent_command = String.trim(Map.get(review_agent_p, "command", ""))

          review_agent =
            %{"kind" => Map.get(review_agent_p, "kind", "claude")}
            |> Map.put(
              "timeout_ms",
              parse_form_int(
                review_agent_p,
                "timeout_ms",
                Map.get(existing_review, "agent", %{}) |> Map.get("timeout_ms", 7_200_000)
              )
            )
            |> then(fn a ->
              if review_agent_command != "",
                do: Map.put(a, "command", review_agent_command),
                else: a
            end)

          Map.put(r, "agent", review_agent)
        else
          Map.delete(r, "agent")
        end
      end)

    new_quality = %{
      "max_cycles" => quality_max_cycles,
      "checks" => new_checks,
      "review" => new_review
    }

    provider_val = Map.get(publish_p, "provider", "")
    mode_val = Map.get(publish_p, "mode", "") |> String.trim()
    pr_type_val = Map.get(publish_p, "pr_type", "ready") |> String.trim()

    new_publish =
      %{}
      |> then(fn p ->
        if provider_val != "", do: Map.put(p, "provider", provider_val), else: p
      end)
      |> then(fn p ->
        if mode_val != "", do: Map.put(p, "mode", mode_val), else: p
      end)
      |> then(fn p ->
        if mode_val == "pr" do
          pr_setting = if(pr_type_val == "draft", do: "draft", else: "ready")
          Map.put(p, "auto_create_pr", pr_setting)
        else
          p
        end
      end)

    base_branch =
      Map.get(git_p, "base_branch", get_in(parsed, ["git", "base_branch"]) || "main")
      |> String.trim()

    parsed
    |> Map.put("agent", new_agent)
    |> Map.put("workspace", %{
      "strategy" =>
        Map.get(workspace_p, "strategy", get_in(parsed, ["workspace", "strategy"]) || "clone")
    })
    |> Map.put("quality", new_quality)
    |> Map.delete("checks")
    |> Map.delete("review")
    |> Map.delete("polling")
    |> Map.put("publish", new_publish)
    |> Map.put("git", %{
      "base_branch" => if(base_branch == "", do: "main", else: base_branch)
    })
  end

  defp to_workflow_yaml(map) do
    ordered_keys =
      map
      |> Map.keys()
      |> Enum.sort_by(fn k -> Enum.find_index(@workflow_yaml_key_order, &(&1 == k)) || 999 end)

    ordered_keys
    |> Enum.map(fn k -> yaml_entry(k, Map.get(map, k), 0) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp yaml_entry(_key, nil, _indent), do: nil

  defp yaml_entry(key, value, indent) do
    prefix = String.duplicate("  ", indent)

    case value do
      v when is_map(v) and map_size(v) == 0 ->
        "#{prefix}#{key}: {}"

      v when is_map(v) ->
        inner =
          v
          |> Enum.sort_by(fn {k, _} -> k end)
          |> Enum.map(fn {k, subv} -> yaml_entry(k, subv, indent + 1) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        "#{prefix}#{key}:\n#{inner}"

      v when is_list(v) and v == [] ->
        "#{prefix}#{key}: []"

      v when is_list(v) ->
        items =
          Enum.map_join(v, "\n", fn item -> "#{prefix}  - #{yaml_scalar(to_string(item))}" end)

        "#{prefix}#{key}:\n#{items}"

      v when is_boolean(v) ->
        "#{prefix}#{key}: #{v}"

      v when is_integer(v) or is_float(v) ->
        "#{prefix}#{key}: #{v}"

      v when is_atom(v) ->
        "#{prefix}#{key}: #{v}"

      v when is_binary(v) ->
        if String.contains?(v, "\n") do
          indented =
            v
            |> String.trim()
            |> String.split("\n")
            |> Enum.map_join("\n", &("#{prefix}  " <> &1))

          "#{prefix}#{key}: |\n#{indented}"
        else
          "#{prefix}#{key}: #{yaml_scalar(v)}"
        end
    end
  end

  defp yaml_scalar(v) when is_binary(v) do
    if Regex.match?(~r/^[a-zA-Z0-9_\-\/\.:~]+$/, v) do
      v
    else
      escaped = v |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
      "\"#{escaped}\""
    end
  end

  defp yaml_scalar(v), do: to_string(v)

  defp parse_form_int(params, key, default) do
    case Map.get(params, key) do
      nil ->
        default

      "" ->
        default

      v ->
        case Integer.parse(to_string(v)) do
          {n, _} when n > 0 -> n
          _ -> default
        end
    end
  end

  defp local_provider?(%{provider: "local"}), do: true
  defp local_provider?(%{provider: :local}), do: true
  defp local_provider?(_), do: false

  defp git_commit_workflow(workflow_path) when is_binary(workflow_path) do
    repo_root = Path.dirname(workflow_path)
    workflow_file = Path.basename(workflow_path)

    {add_out, add_status} =
      System.cmd("git", ["add", workflow_file], cd: repo_root, stderr_to_stdout: true)

    if add_status != 0 do
      Logger.warning(
        "Failed to stage #{workflow_file} after settings save: #{String.trim(add_out)}"
      )
    else
      {commit_out, commit_status} =
        System.cmd("git", ["commit", "-m", "chore: update workflow settings"],
          cd: repo_root,
          stderr_to_stdout: true
        )

      if commit_status != 0 do
        Logger.warning(
          "Failed to commit #{workflow_file} after settings save: #{String.trim(commit_out)}"
        )
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to commit workflow after settings save: #{inspect(error)}")
      :ok
  end

  defp workflow_path(nil), do: nil

  defp workflow_path(project) do
    cond do
      is_binary(project.workflow_path) and project.workflow_path != "" ->
        project.workflow_path

      is_binary(project.local_path) ->
        Path.join([project.local_path, ".kollywood", "WORKFLOW.md"])

      true ->
        nil
    end
  end

  defp load_workflow(project) do
    path = workflow_path(project)

    cond do
      is_nil(path) ->
        %{
          yaml: "",
          body: "",
          parsed: %{},
          review_template: "",
          review_template_is_default: true,
          error: nil,
          path: nil
        }

      not File.exists?(path) ->
        %{
          yaml: "",
          body: "",
          parsed: %{},
          review_template: "",
          review_template_is_default: true,
          error: "File not found: #{path}",
          path: path
        }

      true ->
        case File.read(path) do
          {:ok, content} ->
            case String.split(content, "---", parts: 3) do
              ["", yaml_str, rest] ->
                parsed =
                  case YamlElixir.read_from_string(yaml_str) do
                    {:ok, map} -> map
                    _ -> %{}
                  end

                default_template =
                  String.trim(Kollywood.AgentRunner.default_review_prompt_template())

                stored_template =
                  parsed
                  |> get_in(["quality", "review", "prompt_template"])
                  |> then(fn
                    v when is_binary(v) and v != "" -> String.trim(v)
                    _ -> nil
                  end)

                is_default =
                  is_nil(stored_template) or stored_template == default_template

                %{
                  yaml: String.trim(yaml_str),
                  body: String.trim(rest),
                  parsed: parsed,
                  review_template: stored_template || default_template,
                  review_template_is_default: is_default,
                  error: nil,
                  path: path
                }

              _ ->
                %{
                  yaml: "",
                  body: String.trim(content),
                  parsed: %{},
                  review_template: "",
                  review_template_is_default: true,
                  error: nil,
                  path: path
                }
            end

          {:error, reason} ->
            %{
              yaml: "",
              body: "",
              parsed: %{},
              review_template: "",
              review_template_is_default: true,
              error: "Read error: #{inspect(reason)}",
              path: path
            }
        end
    end
  end

  # Injects or replaces quality.review.prompt_template in full WORKFLOW content.
  defp inject_review_template(content, template) do
    with {:ok, parsed, body} <- parse_workflow_frontmatter(content) do
      updated =
        put_in(
          parsed,
          [Access.key("quality", %{}), Access.key("review", %{}), Access.key("prompt_template")],
          String.trim(template)
        )

      render_workflow_content(updated, body)
    else
      {:error, _reason} ->
        content
    end
  end

  # Removes quality.review.prompt_template from full WORKFLOW content.
  defp remove_review_template(content) do
    with {:ok, parsed, body} <- parse_workflow_frontmatter(content) do
      updated =
        update_in(parsed, [Access.key("quality", %{}), Access.key("review", %{})], fn review ->
          review
          |> Kernel.||(%{})
          |> Map.delete("prompt_template")
        end)

      render_workflow_content(updated, body)
    else
      {:error, _reason} ->
        content
    end
  end

  defp parse_workflow_frontmatter(content) when is_binary(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_str, rest] ->
        parsed =
          case YamlElixir.read_from_string(yaml_str) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        {:ok, parsed, String.trim(rest)}

      _other ->
        {:error, :missing_frontmatter}
    end
  end

  defp render_workflow_content(parsed, body) do
    "---\n#{to_workflow_yaml(parsed)}\n---\n\n#{String.trim(body)}\n"
  end

  defp run_logs_dirs(project) do
    if is_binary(project.slug) and String.trim(project.slug) != "" do
      [ServiceConfig.project_run_logs_path(project.slug)]
    else
      []
    end
  end

  defp cleanup_worktree(project, story_id) do
    with {:ok, config} <- Kollywood.WorkflowStore.get_config(),
         {:ok, workspace} <- Kollywood.Workspace.create_for_issue(story_id, config) do
      Kollywood.Workspace.remove(workspace, config.hooks)
    else
      _ -> :ok
    end

    run_logs_dirs(project)
    |> Enum.each(fn logs_root ->
      story_logs_dir = Path.join(logs_root, story_id)

      if File.dir?(story_logs_dir) do
        File.rm_rf!(story_logs_dir)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  # -- Helpers --

  defp find_project_by_slug(projects, slug) when is_binary(slug) do
    Enum.find(projects, &(&1.slug == slug))
  end

  defp find_project_by_slug(_projects, _slug), do: nil

  defp normalize_stories_view("list"), do: "list"
  defp normalize_stories_view("kanban"), do: "kanban"

  defp normalize_stories_view(view) when is_binary(view) do
    case view |> String.trim() |> String.downcase() do
      "list" -> "list"
      "kanban" -> "kanban"
      _other -> @default_stories_view
    end
  end

  defp normalize_stories_view(_view), do: @default_stories_view

  defp normalize_status(nil), do: "open"

  defp normalize_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp display_status(status) do
    status
    |> normalize_status()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp parse_attempt(nil), do: nil

  defp parse_attempt(value) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} -> num
      _ -> nil
    end
  end

  defp parse_attempt(value) when is_integer(value), do: value
  defp parse_attempt(_), do: nil

  defp run_number(value) do
    case parse_attempt(value) do
      num when is_integer(num) and num > 0 -> "##{num}"
      _other -> to_string(value)
    end
  end

  defp story_tracker_run_attempt(story) when is_map(story) do
    story
    |> Map.get("lastRunAttempt", Map.get(story, "lastAttempt"))
    |> normalize_story_attempt()
  end

  defp story_tracker_run_attempt(_story), do: nil

  defp normalize_story_attempt(value) when is_integer(value) and value > 0, do: value

  defp normalize_story_attempt(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      is_integer(parse_attempt(trimmed)) -> parse_attempt(trimmed)
      true -> trimmed
    end
  end

  defp normalize_story_attempt(_value), do: nil

  defp format_time(nil), do: "—"

  defp format_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> time_str
    end
  end

  defp format_time(_), do: "—"

  defp format_relative_time(nil), do: "—"

  defp format_relative_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _} -> time_ago(dt)
      _ -> "—"
    end
  end

  defp format_relative_time(_), do: "—"

  defp format_time_tooltip(nil), do: ""

  defp format_time_tooltip(time_str) when is_binary(time_str) do
    format_time(time_str)
  end

  defp format_time_tooltip(_), do: ""

  defp format_duration(nil, _), do: "—"
  defp format_duration(_, nil), do: "—"

  defp format_duration(started_at, ended_at) when is_binary(started_at) and is_binary(ended_at) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(started_at),
         {:ok, end_dt, _} <- DateTime.from_iso8601(ended_at) do
      seconds = DateTime.diff(end_dt, start_dt)
      if seconds < 60, do: "#{seconds}s", else: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    else
      _ -> "—"
    end
  end

  defp format_duration(_, _), do: "—"

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "…"
  end

  defp truncate(str, _max), do: str

  defp handle_live_action(socket, :settings, _params) do
    assign(socket, :workflow, load_workflow(socket.assigns.current_project))
  end

  defp handle_live_action(socket, :run_detail, params) do
    story_id = params["story_id"]
    attempt = params["attempt"]
    project = socket.assigns.current_project

    cond do
      !project ->
        socket

      is_binary(attempt) ->
        tab = socket.assigns.active_log_tab
        run_detail = load_run_detail_for_attempt(project, story_id, attempt, tab)

        socket =
          socket
          |> assign(:run_detail, run_detail)

        if run_detail && get_in(run_detail, ["metadata", "status"]) == "running" do
          {:ok, timer} = :timer.send_interval(1000, self(), :poll_logs)
          assign(socket, :log_poll_timer, timer)
        else
          assign(socket, :log_poll_timer, nil)
        end

      true ->
        push_navigate(socket,
          to: ~p"/projects/#{project.slug}/stories/#{story_id}?tab=runs"
        )
    end
  end

  defp handle_live_action(socket, :story_detail, params) do
    story_id = params["story_id"]
    attempt = params["attempt"]
    story = Enum.find(socket.assigns.stories, &(&1["id"] == story_id))
    tab = socket.assigns.active_log_tab
    project = socket.assigns.current_project
    story_tab = if attempt, do: params["tab"] || "runs", else: params["tab"] || "details"

    run_detail =
      if attempt do
        load_run_detail_for_attempt(project, story_id, attempt, tab)
      else
        load_run_detail_latest(project, story_id, tab)
      end

    socket =
      socket
      |> assign(:selected_story, story)
      |> assign(:run_detail, run_detail)
      |> assign(:story_detail_tab, story_tab)

    if run_detail && get_in(run_detail, ["metadata", "status"]) == "running" do
      {:ok, timer} = :timer.send_interval(1000, self(), :poll_logs)
      assign(socket, :log_poll_timer, timer)
    else
      assign(socket, :log_poll_timer, nil)
    end
  end

  defp handle_live_action(socket, _action, _params), do: socket

  defp cancel_poll_timer(socket) do
    case socket.assigns[:log_poll_timer] do
      nil ->
        socket

      timer ->
        :timer.cancel(timer)
        assign(socket, :log_poll_timer, nil)
    end
  end

  defp load_run_detail_latest(nil, _story_id, _tab), do: nil
  defp load_run_detail_latest(_project, nil, _tab), do: nil

  defp load_run_detail_latest(project, story_id, tab) do
    project
    |> derive_project_roots()
    |> Enum.find_value(fn project_root ->
      case RunLogs.resolve_attempt(project_root, story_id, :latest) do
        {:ok, %{metadata: metadata, files: files}} ->
          content = read_log_tab_content(files, tab)

          %{
            "metadata" => metadata,
            "active_log_content" => content
          }

        {:error, _} ->
          nil
      end
    end)
  end

  defp load_run_detail_for_attempt(nil, _story_id, _attempt, _tab), do: nil
  defp load_run_detail_for_attempt(_project, nil, _attempt, _tab), do: nil

  defp load_run_detail_for_attempt(project, story_id, attempt, tab) do
    parsed = parse_attempt(attempt)

    if parsed do
      project
      |> derive_project_roots()
      |> Enum.find_value(fn project_root ->
        case RunLogs.resolve_attempt(project_root, story_id, parsed) do
          {:ok, %{metadata: metadata, files: files}} ->
            content = read_log_tab_content(files, tab)

            %{
              "metadata" => metadata,
              "active_log_content" => content
            }

          {:error, _} ->
            nil
        end
      end)
    end
  end

  defp derive_project_roots(project) do
    if is_binary(project.slug) and String.trim(project.slug) != "" do
      [ServiceConfig.project_data_dir(project.slug)]
    else
      []
    end
  end

  @log_tab_file_keys %{
    "agent" => :agent_stdout,
    "review_agent" => :reviewer_stdout,
    "worker" => :run
  }

  @ansi_color_palette %{
    black: "#111827",
    red: "#dc2626",
    green: "#16a34a",
    yellow: "#ca8a04",
    blue: "#2563eb",
    magenta: "#c026d3",
    cyan: "#0891b2",
    white: "#d1d5db",
    bright_black: "#6b7280",
    bright_red: "#ef4444",
    bright_green: "#22c55e",
    bright_yellow: "#facc15",
    bright_blue: "#60a5fa",
    bright_magenta: "#e879f9",
    bright_cyan: "#22d3ee",
    bright_white: "#f9fafb"
  }

  @ansi_fg_codes %{
    30 => :black,
    31 => :red,
    32 => :green,
    33 => :yellow,
    34 => :blue,
    35 => :magenta,
    36 => :cyan,
    37 => :white,
    90 => :bright_black,
    91 => :bright_red,
    92 => :bright_green,
    93 => :bright_yellow,
    94 => :bright_blue,
    95 => :bright_magenta,
    96 => :bright_cyan,
    97 => :bright_white
  }

  @ansi_bg_codes %{
    40 => :black,
    41 => :red,
    42 => :green,
    43 => :yellow,
    44 => :blue,
    45 => :magenta,
    46 => :cyan,
    47 => :white,
    100 => :bright_black,
    101 => :bright_red,
    102 => :bright_green,
    103 => :bright_yellow,
    104 => :bright_blue,
    105 => :bright_magenta,
    106 => :bright_cyan,
    107 => :bright_white
  }

  @ansi_default_style %{fg: nil, bg: nil, bold: false, dim: false}

  attr :content, :string, default: nil

  defp ansi_log(assigns) do
    assigns = assign(assigns, :segments, ansi_segments(assigns.content))

    ~H"""
    <%= for segment <- @segments do %>
      <%= if segment.style do %>
        <span style={segment.style}>{segment.text}</span>
      <% else %>
        {segment.text}
      <% end %>
    <% end %>
    """
  end

  defp read_log_tab_content(files, tab) when is_map(files) and is_binary(tab) do
    key = Map.get(@log_tab_file_keys, tab, String.to_atom(tab))
    file_path = Map.get(files, key)

    case file_path && File.read(file_path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp read_log_tab_content(_files, _tab), do: nil

  defp parse_ansi_segments(<<>>, _style, acc), do: acc

  defp parse_ansi_segments(content, style, acc) do
    case :binary.match(content, <<27, 91>>) do
      :nomatch ->
        append_segment(acc, sanitize_log_chunk(content), style)

      {index, _length} ->
        prefix = binary_part(content, 0, index)
        rest = binary_part(content, index + 2, byte_size(content) - index - 2)
        acc = append_segment(acc, sanitize_log_chunk(prefix), style)

        case take_ansi_sequence(rest, <<>>) do
          {:ok, params, ?m, remaining} ->
            parse_ansi_segments(remaining, apply_sgr(params, style), acc)

          {:ok, params, terminator, remaining} ->
            acc = append_segment(acc, sanitize_log_chunk(<<params::binary, terminator>>), style)
            parse_ansi_segments(remaining, style, acc)

          :error ->
            parse_ansi_segments(rest, style, acc)
        end
    end
  end

  defp take_ansi_sequence(<<>>, _acc), do: :error

  defp take_ansi_sequence(<<byte, rest::binary>>, acc) when byte >= 0x40 and byte <= 0x7E do
    {:ok, acc, byte, rest}
  end

  defp take_ansi_sequence(<<byte, rest::binary>>, acc) do
    take_ansi_sequence(rest, <<acc::binary, byte>>)
  end

  defp apply_sgr(params, style) do
    params
    |> decode_sgr_codes()
    |> apply_sgr_codes(style)
  end

  defp decode_sgr_codes("") do
    [0]
  end

  defp decode_sgr_codes(params) do
    params
    |> String.split(";", trim: false)
    |> Enum.map(fn
      "" ->
        0

      part ->
        case Integer.parse(part) do
          {code, ""} -> code
          _ -> :invalid
        end
    end)
  end

  defp apply_sgr_codes([], style), do: style

  defp apply_sgr_codes([:invalid | rest], style), do: apply_sgr_codes(rest, style)

  defp apply_sgr_codes([0 | rest], _style), do: apply_sgr_codes(rest, @ansi_default_style)

  defp apply_sgr_codes([1 | rest], style),
    do: apply_sgr_codes(rest, %{style | bold: true, dim: false})

  defp apply_sgr_codes([2 | rest], style),
    do: apply_sgr_codes(rest, %{style | dim: true, bold: false})

  defp apply_sgr_codes([22 | rest], style),
    do: apply_sgr_codes(rest, %{style | dim: false, bold: false})

  defp apply_sgr_codes([39 | rest], style), do: apply_sgr_codes(rest, %{style | fg: nil})

  defp apply_sgr_codes([49 | rest], style), do: apply_sgr_codes(rest, %{style | bg: nil})

  defp apply_sgr_codes([code | rest], style) when is_integer(code) do
    cond do
      fg = Map.get(@ansi_fg_codes, code) ->
        apply_sgr_codes(rest, %{style | fg: fg})

      bg = Map.get(@ansi_bg_codes, code) ->
        apply_sgr_codes(rest, %{style | bg: bg})

      true ->
        apply_sgr_codes(rest, style)
    end
  end

  defp append_segment(acc, "", _style), do: acc

  defp append_segment([{text, same_style} | rest], chunk, same_style) do
    [{text <> chunk, same_style} | rest]
  end

  defp append_segment(acc, chunk, style) do
    [{chunk, style} | acc]
  end

  defp sanitize_log_chunk(chunk) do
    String.replace(chunk, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "")
  end

  defp ansi_style_to_attr(%{fg: nil, bg: nil, bold: false, dim: false}), do: nil

  defp ansi_style_to_attr(style) do
    [
      style.fg && "color: #{Map.get(@ansi_color_palette, style.fg)}",
      style.bg && "background-color: #{Map.get(@ansi_color_palette, style.bg)}",
      style.bold && "font-weight: 700",
      style.dim && "opacity: 0.7"
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp ansi_segments(nil), do: []

  defp ansi_segments(content) when is_binary(content) do
    content
    |> parse_ansi_segments(@ansi_default_style, [])
    |> Enum.reverse()
    |> Enum.map(fn {text, style} -> %{text: text, style: ansi_style_to_attr(style)} end)
  end

  defp ansi_segments(_), do: []

  defp markdown_to_html(nil), do: ""

  defp markdown_to_html(text) when is_binary(text) do
    MDEx.to_html!(text)
  end

  defp markdown_to_html(_), do: ""

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_list(value), do: value != []
  defp present?(_), do: false

  defp fetch_orchestrator_status do
    Kollywood.Orchestrator.status()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp time_ago(nil), do: "never"

  defp time_ago(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> time_ago(dt)
      _ -> "unknown"
    end
  end

  defp time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      true -> "#{div(diff, 3600)}h ago"
    end
  end

  defp time_ago(_), do: "unknown"
end
