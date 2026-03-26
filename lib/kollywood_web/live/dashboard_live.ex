defmodule KollywoodWeb.DashboardLive do
  @moduledoc """
  Project-scoped dashboard with navigation, real story/run data,
  and run detail with logs.
  """
  use KollywoodWeb, :live_view

  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.Projects.Project

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
      |> load_project_data(current_project)
      |> handle_live_action(socket.assigns[:live_action], params)

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket =
      socket
      |> load_project_data(socket.assigns.current_project)
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

  def handle_event("update_story_status", %{"id" => id, "status" => status}, socket) do
    project = socket.assigns.current_project

    socket =
      with %{tracker_path: path} when is_binary(path) <- project,
           true <- File.exists?(path),
           {:ok, content} <- File.read(path),
           {:ok, data} <- Jason.decode(content) do
        updated_stories =
          Enum.map(Map.get(data, "userStories", []), fn story ->
            if story["id"] == id, do: Map.put(story, "status", status), else: story
          end)

        File.write!(
          path,
          Jason.encode!(Map.put(data, "userStories", updated_stories), pretty: true)
        )

        assign(socket, :stories, read_stories(project))
      else
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("reset_story", %{"id" => id}, socket) do
    project = socket.assigns.current_project

    socket =
      with %{tracker_path: path} when is_binary(path) <- project,
           true <- File.exists?(path),
           :ok <- Kollywood.Tracker.PrdJson.reset_story(path, id) do
        cleanup_worktree(project, id)
        assign(socket, :stories, read_stories(project))
      else
        _ -> socket
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
      case workflow_path(project) do
        nil ->
          socket

        path ->
          content = "---\n#{String.trim(yaml)}\n---\n\n#{String.trim(body)}\n"

          case File.write(path, content) do
            :ok ->
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

    {:noreply, socket}
  end

  def handle_event("save_review_template", %{"review_template" => template}, socket) do
    project = socket.assigns.current_project

    socket =
      case workflow_path(project) do
        nil ->
          socket

        path ->
          with {:ok, content} <- File.read(path),
               new_yaml <- inject_review_template(content, String.trim(template)),
               :ok <- File.write(path, new_yaml) do
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
                />
              <% :stories -> %>
                <.stories_section stories={@stories} project={@current_project} />
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
                <.settings_section project={@current_project} workflow={@workflow} />
              <% _ -> %>
                <.overview_section
                  counters={@counters}
                  stories={@stories}
                  orchestrator_status={@orchestrator_status}
                  project={@current_project}
                />
            <% end %>
          </div>
        </main>
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
          <% recent_activity = @stories |> Enum.filter(&is_binary(&1["lastAttempt"])) |> Enum.take(10) %>
          <%= if recent_activity == [] do %>
            <p class="text-base-content/60 py-4">No recent activity</p>
          <% else %>
            <div class="space-y-1 mt-2">
              <%= for story <- recent_activity do %>
                <.link
                  navigate={~p"/projects/#{@project.slug}/runs/#{story["id"]}"}
                  class="flex flex-col sm:flex-row sm:items-center gap-1 sm:gap-3 p-3 bg-base-100 rounded-lg hover:bg-base-300 transition-colors"
                >
                  <div class="flex items-center gap-2 min-w-0">
                    <.status_badge status={story["status"] || "open"} />
                    <span class="font-mono text-xs text-base-content/60 shrink-0">{story["id"]}</span>
                    <span class="text-sm truncate">{story["title"]}</span>
                  </div>
                  <%= if story["lastError"] do %>
                    <span class="text-xs text-error truncate sm:ml-auto">
                      {truncate(story["lastError"], 60)}
                    </span>
                  <% end %>
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

  defp stories_section(assigns) do
    groups = %{
      "in_progress" =>
        Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "in_progress")),
      "open" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "open")),
      "done" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "done")),
      "failed" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "failed")),
      "draft" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "draft"))
    }

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Stories</h2>

      <%= if @stories == [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-document-text" class="size-12 text-base-content/20 mb-2" />
            <p class="text-base-content/60">
              No stories yet. Add stories to prd.json to get started.
            </p>
          </div>
        </div>
      <% end %>

      <%= for {status, label} <- [{"in_progress", "In Progress"}, {"open", "Open"}, {"done", "Done"}, {"failed", "Failed"}] do %>
        <% stories = Map.get(@groups, status, []) %>
        <%= if stories != [] do %>
          <div>
            <h3 class="text-lg font-semibold mb-3 flex items-center gap-2">
              <.status_badge status={status} />
              {label}
              <span class="badge badge-sm badge-ghost">{length(stories)}</span>
            </h3>
            <div class="space-y-2">
              <%= for story <- stories do %>
                <div id={"story-card-#{story["id"]}"} class="card bg-base-200 border border-base-300">
                  <div class="card-body p-4">
                    <div class="flex items-start justify-between gap-4">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                          <.link
                            navigate={~p"/projects/#{@project.slug}/stories/#{story["id"]}"}
                            class="font-mono text-sm font-semibold text-primary hover:underline"
                          >
                            {story["id"]}
                          </.link>
                          <.link
                            navigate={~p"/projects/#{@project.slug}/stories/#{story["id"]}"}
                            class="font-medium hover:text-primary text-left"
                          >
                            {story["title"]}
                          </.link>
                        </div>
                        <%= if story["dependsOn"] && story["dependsOn"] != [] do %>
                          <div class="flex items-center gap-1 mt-1">
                            <span class="text-xs text-base-content/50">depends on:</span>
                            <%= for dep <- story["dependsOn"] do %>
                              <span class="badge badge-xs badge-outline">{dep}</span>
                            <% end %>
                          </div>
                        <% end %>
                        <%= if story["lastError"] do %>
                          <p class="text-sm text-error mt-2 line-clamp-2">{story["lastError"]}</p>
                        <% end %>
                      </div>
                      <div class="flex items-center gap-2 shrink-0">
                        <%= if story["lastAttempt"] do %>
                          <span class="badge badge-sm badge-ghost">
                            attempt {story["lastAttempt"]}
                          </span>
                        <% end %>
                        <%= if normalize_status(story["status"]) != "open" do %>
                          <button
                            phx-click="reset_story"
                            phx-value-id={story["id"]}
                            phx-confirm={"Reset #{story["id"]}? This will clear run data and remove the worktree."}
                            class="btn btn-ghost btn-xs text-warning"
                          >
                            Reset
                          </button>
                        <% end %>
                        <div class="dropdown dropdown-end">
                          <label tabindex="0" class="btn btn-ghost btn-xs">
                            <.icon name="hero-pencil-square" class="size-4" />
                          </label>
                          <ul
                            tabindex="0"
                            class="dropdown-content menu menu-xs bg-base-100 rounded-box shadow-lg border border-base-300 z-50 w-36 p-1"
                          >
                            <%= for s <- ["open", "in_progress", "done", "failed", "cancelled", "draft"] do %>
                              <li>
                                <button
                                  phx-click="update_story_status"
                                  phx-value-id={story["id"]}
                                  phx-value-status={s}
                                  class="text-xs"
                                >
                                  {s}
                                </button>
                              </li>
                            <% end %>
                          </ul>
                        </div>
                        <.link
                          navigate={~p"/projects/#{@project.slug}/runs"}
                          class="btn btn-ghost btn-xs"
                        >
                          Runs →
                        </.link>
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      <% end %>

      <%= if @groups["draft"] != [] do %>
        <div class="opacity-60">
          <h3 class="text-lg font-semibold mb-3 flex items-center gap-2">
            <.status_badge status="draft" /> Draft
            <span class="badge badge-sm badge-ghost">{length(@groups["draft"])}</span>
          </h3>
          <div class="space-y-2">
            <%= for story <- @groups["draft"] do %>
              <div
                id={"story-card-#{story["id"]}"}
                class="card bg-base-200 border border-base-300 border-dashed"
              >
                <div class="card-body p-4">
                  <div class="flex items-start justify-between gap-4">
                    <div class="flex-1 min-w-0">
                      <div class="flex items-center gap-2">
                        <.link
                          navigate={~p"/projects/#{@project.slug}/stories/#{story["id"]}"}
                          class="font-mono text-sm font-semibold text-primary hover:underline"
                        >
                          {story["id"]}
                        </.link>
                        <.link
                          navigate={~p"/projects/#{@project.slug}/stories/#{story["id"]}"}
                          class="font-medium hover:text-primary text-left"
                        >
                          {story["title"]}
                        </.link>
                      </div>
                      <%= if story["dependsOn"] && story["dependsOn"] != [] do %>
                        <div class="flex items-center gap-1 mt-1">
                          <span class="text-xs text-base-content/50">depends on:</span>
                          <%= for dep <- story["dependsOn"] do %>
                            <span class="badge badge-xs badge-outline">{dep}</span>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                    <div class="flex items-center gap-2 shrink-0">
                      <div class="dropdown dropdown-end">
                        <label tabindex="0" class="btn btn-ghost btn-xs">
                          <.icon name="hero-pencil-square" class="size-4" />
                        </label>
                        <ul
                          tabindex="0"
                          class="dropdown-content menu menu-xs bg-base-100 rounded-box shadow-lg border border-base-300 z-50 w-36 p-1"
                        >
                          <%= for s <- ["open", "in_progress", "done", "failed", "cancelled", "draft"] do %>
                            <li>
                              <button
                                phx-click="update_story_status"
                                phx-value-id={story["id"]}
                                phx-value-status={s}
                                class="text-xs"
                              >
                                {s}
                              </button>
                            </li>
                          <% end %>
                        </ul>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Runs Section --

  attr :run_attempts, :list, required: true
  attr :project, Project, required: true
  attr :stories, :list, default: []

  defp runs_section(assigns) do
    # Fall back to stories with lastAttempt when no run_attempts available from disk
    story_runs = Enum.filter(assigns.stories, &is_binary(&1["lastAttempt"]))
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
                <th>Attempt</th>
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
                  <td>{run.attempt}</td>
                  <td><.run_status_badge status={run.status} /></td>
                  <td class="text-sm text-base-content/70">{format_time(run.started_at)}</td>
                  <td class="text-sm text-base-content/70">{format_time(run.ended_at)}</td>
                  <td>
                    <.link
                      patch={~p"/projects/#{@project.slug}/runs/#{run.story_id}"}
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
                  <th>Attempt</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for story <- @story_runs do %>
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
                    <td class="text-sm text-base-content/60">{story["lastAttempt"]}</td>
                    <td>
                      <.link
                        navigate={~p"/projects/#{@project.slug}/runs/#{story["id"]}"}
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
        <.link patch={~p"/projects/#{@project.slug}/runs"} class="btn btn-ghost btn-sm gap-2">
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
            {"worker", "Worker"},
            {"checks", "Checks"},
            {"reviewer", "Reviewer"},
            {"runtime", "Runtime"}
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
          >{@run_detail["active_log_content"]}</pre>
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
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link navigate={~p"/projects/#{@project.slug}/stories"} class="btn btn-ghost btn-sm gap-2">
          <.icon name="hero-arrow-left" class="size-4" /> Back to Stories
        </.link>
        <span class="badge badge-outline font-mono text-sm">{@story_id}</span>
        <%= if @story do %>
          <.status_badge status={@story["status"] || "open"} />
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
                <p class="text-sm">{@story["description"]}</p>
              </div>
            <% end %>

            <%= if criteria = @story["acceptanceCriteria"] do %>
              <%= if criteria != [] do %>
                <div>
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Acceptance Criteria
                  </h3>
                  <ul class="list-disc list-inside space-y-1">
                    <%= for criterion <- criteria do %>
                      <li class="text-sm">{criterion}</li>
                    <% end %>
                  </ul>
                </div>
              <% end %>
            <% end %>

            <%= if @story["notes"] do %>
              <div>
                <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Notes
                </h3>
                <p class="text-sm text-base-content/70">{@story["notes"]}</p>
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
              <span class="text-sm text-base-content/60">Attempt #{@selected_attempt}</span>
            </div>

            <div class="flex gap-0 border-b border-base-300">
              <%= for {tab, label} <- [
                {"agent", "Agent"},
                {"worker", "Worker"},
                {"checks", "Checks"},
                {"reviewer", "Reviewer"},
                {"runtime", "Runtime"}
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
              >{@run_detail["active_log_content"]}</pre>
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
                        <th>Attempt</th>
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
                                ~p"/projects/#{@project.slug}/stories/#{@story_id}?attempt=#{run.attempt}&tab=runs"
                              }
                              class="font-mono text-sm hover:text-primary"
                            >
                              #{"#{run.attempt}" |> String.pad_leading(4, "0")}
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
                      <%= for k <- ["amp", "claude", "opencode", "pi"] do %>
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

              <%!-- Checks --%>
              <div>
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
                      name="settings[checks][required]"
                      rows="4"
                      spellcheck="false"
                      class="textarea textarea-bordered textarea-sm w-full font-mono text-xs"
                    >{(get_in(@workflow.parsed, ["checks", "required"]) || []) |> Enum.join("\n")}</textarea>
                  </div>
                  <div class="grid sm:grid-cols-2 gap-4">
                    <div>
                      <label class="label pb-1">
                        <span class="label-text text-sm">Timeout (ms)</span>
                      </label>
                      <input
                        type="number"
                        min="1000"
                        step="1000"
                        name="settings[checks][timeout_ms]"
                        value={get_in(@workflow.parsed, ["checks", "timeout_ms"]) || 7_200_000}
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <div class="flex items-center gap-2 pt-5">
                      <input type="hidden" name="settings[checks][fail_fast]" value="false" />
                      <input
                        type="checkbox"
                        name="settings[checks][fail_fast]"
                        value="true"
                        checked={get_in(@workflow.parsed, ["checks", "fail_fast"]) != false}
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
                    <input type="hidden" name="settings[review][enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[review][enabled]"
                      value="true"
                      checked={get_in(@workflow.parsed, ["review", "enabled"]) == true}
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
                      name="settings[review][max_cycles]"
                      value={get_in(@workflow.parsed, ["review", "max_cycles"]) || 1}
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
                      name="settings[review][pass_token]"
                      value={get_in(@workflow.parsed, ["review", "pass_token"]) || "REVIEW_PASS"}
                      class="input input-bordered input-sm w-full font-mono"
                    />
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Fail Token</span>
                    </label>
                    <input
                      type="text"
                      name="settings[review][fail_token]"
                      value={get_in(@workflow.parsed, ["review", "fail_token"]) || "REVIEW_FAIL"}
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
                          name="settings[review][agent_custom]"
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name="settings[review][agent_custom]"
                          value="true"
                          checked={get_in(@workflow.parsed, ["review", "agent"]) != nil}
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
                            name="settings[review][agent][kind]"
                            class="select select-bordered select-sm w-full"
                          >
                            <%= for k <- ["amp", "claude", "opencode", "pi"] do %>
                              <option
                                value={k}
                                selected={
                                  (get_in(@workflow.parsed, ["review", "agent", "kind"]) ||
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
                            name="settings[review][agent][timeout_ms]"
                            value={
                              get_in(@workflow.parsed, ["review", "agent", "timeout_ms"]) ||
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
                            name="settings[review][agent][command]"
                            value={get_in(@workflow.parsed, ["review", "agent", "command"]) || ""}
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
                      <span class="label-text text-sm">Auto Push</span>
                    </label>
                    <select
                      name="settings[publish][auto_push]"
                      class="select select-bordered select-sm w-full"
                    >
                      <%= for v <- ["never", "on_pass"] do %>
                        <option
                          value={v}
                          selected={
                            to_string(get_in(@workflow.parsed, ["publish", "auto_push"])) == v
                          }
                        >
                          {v}
                        </option>
                      <% end %>
                    </select>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Auto Create PR</span>
                    </label>
                    <select
                      name="settings[publish][auto_create_pr]"
                      class="select select-bordered select-sm w-full"
                    >
                      <%= for v <- ["never", "draft", "ready"] do %>
                        <option
                          value={v}
                          selected={
                            to_string(get_in(@workflow.parsed, ["publish", "auto_create_pr"])) == v
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
                    review.prompt_template
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
                  <p class="text-xs text-base-content/50">Custom template active for this project.</p>
                <% end %>
                <button type="submit" class="btn btn-primary btn-sm">Save Review Template</button>
              </div>
            </form>
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
    color =
      case assigns.status do
        "running" -> "badge-warning"
        "ok" -> "badge-success"
        "finished" -> "badge-success"
        "failed" -> "badge-error"
        "stopped" -> "badge-ghost"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>{@status}</span>
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

  # -- Data Loading --

  defp load_project_data(socket, nil) do
    assign(socket,
      stories: [],
      counters: %{open: 0, in_progress: 0, done: 0, failed: 0},
      run_attempts: [],
      run_detail: nil,
      run_detail_story_id: nil,
      run_detail_attempt: nil
    )
  end

  defp load_project_data(socket, project) do
    stories = read_stories(project)
    counters = count_stories(stories)
    run_attempts = list_run_attempts(project)

    socket =
      socket
      |> assign(:stories, stories)
      |> assign(:counters, counters)
      |> assign(:run_attempts, run_attempts)

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

  defp read_stories(project) do
    path = project.tracker_path

    if is_binary(path) and File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, decoded} <- Jason.decode(content) do
        Map.get(decoded, "userStories", [])
      else
        _ -> []
      end
    else
      []
    end
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
    log_root = run_logs_dir(project)

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
      |> Enum.sort_by(& &1.started_at, :desc)
    else
      []
    end
  rescue
    _ -> []
  end

  defp load_run_detail(project, story_id, attempt) when is_binary(attempt) do
    # Try new string-based path first (local_path/runs/story_id/attempt)
    # then fall back to old numeric padded path (.kollywood/run_logs/story_id/attempt-NNNN)
    local_runs_dir =
      if is_binary(project.local_path) do
        Path.join([project.local_path, "runs", story_id, attempt])
      end

    parsed_attempt = parse_attempt(attempt)

    old_attempt_dir =
      if parsed_attempt do
        Path.join([run_logs_dir(project), story_id, "attempt-#{pad_attempt(parsed_attempt)}"])
      end

    attempt_dir =
      cond do
        local_runs_dir && File.dir?(local_runs_dir) -> local_runs_dir
        old_attempt_dir && File.dir?(old_attempt_dir) -> old_attempt_dir
        true -> nil
      end

    if attempt_dir do
      metadata_path = Path.join(attempt_dir, "metadata.json")

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

      metadata
      |> Map.put("run_log", safe_read(Path.join(attempt_dir, "run.log")))
      |> Map.put("worker_log", safe_read(Path.join(attempt_dir, "worker.log")))
      |> Map.put("reviewer_log", safe_read(Path.join(attempt_dir, "reviewer.log")))
      |> Map.put("checks_log", safe_read(Path.join(attempt_dir, "checks.log")))
    else
      nil
    end
  end

  defp load_run_detail(project, story_id, attempt) do
    parsed = parse_attempt(attempt)

    if parsed do
      attempt_dir = Path.join([run_logs_dir(project), story_id, "attempt-#{pad_attempt(parsed)}"])

      if File.dir?(attempt_dir) do
        metadata_path = Path.join(attempt_dir, "metadata.json")

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

        metadata
        |> Map.put("run_log", safe_read(Path.join(attempt_dir, "run.log")))
        |> Map.put("worker_log", safe_read(Path.join(attempt_dir, "worker.log")))
        |> Map.put("reviewer_log", safe_read(Path.join(attempt_dir, "reviewer.log")))
        |> Map.put("checks_log", safe_read(Path.join(attempt_dir, "checks.log")))
      else
        nil
      end
    else
      nil
    end
  end

  # -- Settings Helpers --

  @workflow_yaml_key_order ~w(tracker polling workspace agent checks runtime hooks review publish git)

  defp apply_settings(parsed, settings) do
    agent_p = Map.get(settings, "agent", %{})
    workspace_p = Map.get(settings, "workspace", %{})
    checks_p = Map.get(settings, "checks", %{})
    review_p = Map.get(settings, "review", %{})
    publish_p = Map.get(settings, "publish", %{})
    git_p = Map.get(settings, "git", %{})

    existing_agent = Map.get(parsed, "agent", %{})
    existing_checks = Map.get(parsed, "checks", %{})
    existing_review = Map.get(parsed, "review", %{})

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

    new_checks = %{
      "required" => checks_required,
      "fail_fast" => Map.get(checks_p, "fail_fast") == "true",
      "timeout_ms" =>
        parse_form_int(checks_p, "timeout_ms", Map.get(existing_checks, "timeout_ms", 7_200_000))
    }

    existing_prompt_template = get_in(parsed, ["review", "prompt_template"])
    review_agent_custom = Map.get(review_p, "agent_custom") == "true"
    review_agent_p = Map.get(review_p, "agent", %{})

    new_review =
      %{
        "enabled" => Map.get(review_p, "enabled") == "true",
        "max_cycles" =>
          parse_form_int(review_p, "max_cycles", Map.get(existing_review, "max_cycles", 1)),
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

    provider_val = Map.get(publish_p, "provider", "")

    new_publish =
      %{
        "auto_push" => Map.get(publish_p, "auto_push", "never"),
        "auto_create_pr" => Map.get(publish_p, "auto_create_pr", "never")
      }
      |> then(fn p ->
        if provider_val != "", do: Map.put(p, "provider", provider_val), else: p
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
    |> Map.put("checks", new_checks)
    |> Map.put("review", new_review)
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

  defp workflow_path(nil), do: nil

  defp workflow_path(project) do
    cond do
      is_binary(project.workflow_path) and project.workflow_path != "" ->
        project.workflow_path

      is_binary(project.local_path) ->
        Path.join(project.local_path, "WORKFLOW.md")

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

                custom_review_template =
                  parsed
                  |> get_in(["review", "prompt_template"])
                  |> then(fn
                    v when is_binary(v) and v != "" -> String.trim(v)
                    _ -> nil
                  end)

                %{
                  yaml: String.trim(yaml_str),
                  body: String.trim(rest),
                  parsed: parsed,
                  review_template:
                    custom_review_template ||
                      String.trim(Kollywood.AgentRunner.default_review_prompt_template()),
                  review_template_is_default: is_nil(custom_review_template),
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

  # Injects or replaces the review.prompt_template block scalar in the full WORKFLOW.md content.
  # Operates on lines to avoid needing a YAML encoder.
  defp inject_review_template(content, template) do
    indented_template =
      template
      |> String.trim()
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    new_block_lines = ["  prompt_template: |", indented_template]

    lines = String.split(content, "\n")

    {result, _state, found?} =
      Enum.reduce(lines, {[], :scanning, false}, fn line, {acc, state, found} ->
        case state do
          :scanning ->
            if String.trim(line) == "review:" do
              {acc ++ [line], :in_review, found}
            else
              {acc ++ [line], :scanning, found}
            end

          :in_review ->
            trimmed = String.trim_leading(line)

            cond do
              String.starts_with?(trimmed, "prompt_template:") ->
                {acc ++ new_block_lines, :skip_template, true}

              line == "" ->
                {acc ++ [line], :in_review, found}

              not String.starts_with?(line, " ") ->
                {acc ++ [line], :scanning, found}

              true ->
                {acc ++ [line], :in_review, found}
            end

          :skip_template ->
            # Skip old template content lines (indented 4+ spaces), resume on 2-space keys or top-level
            cond do
              String.starts_with?(line, "    ") ->
                {acc, :skip_template, found}

              String.starts_with?(line, "  ") and not String.starts_with?(line, "    ") ->
                {acc ++ [line], :in_review, found}

              not String.starts_with?(line, " ") and line != "" ->
                {acc ++ [line], :scanning, found}

              true ->
                {acc, :skip_template, found}
            end
        end
      end)

    result_str = Enum.join(result, "\n")

    if found? do
      result_str
    else
      # prompt_template not found — append it under review: if review: exists, else append section
      if String.match?(content, ~r/^review:/m) do
        Regex.replace(~r/^(review:.*?)(\n(?=\S)|\z)/ms, content, fn _, review_block, tail ->
          "#{String.trim_trailing(review_block)}\n#{Enum.join(new_block_lines, "\n")}#{tail}"
        end)
      else
        String.trim_trailing(content) <>
          "\nreview:\n" <> Enum.join(new_block_lines, "\n") <> "\n"
      end
    end
  end

  defp run_logs_dir(project) do
    if is_binary(project.local_path) do
      Path.join(project.local_path, ".kollywood/run_logs")
    else
      ""
    end
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp cleanup_worktree(project, story_id) do
    with {:ok, config} <- Kollywood.WorkflowStore.get_config(),
         {:ok, workspace} <- Kollywood.Workspace.create_for_issue(story_id, config) do
      Kollywood.Workspace.remove(workspace, config.hooks)
    else
      _ -> :ok
    end

    story_logs_dir = Path.join(run_logs_dir(project), story_id)

    if File.dir?(story_logs_dir) do
      File.rm_rf!(story_logs_dir)
    end

    :ok
  rescue
    _ -> :ok
  end

  # -- Helpers --

  defp find_project_by_slug(projects, slug) when is_binary(slug) do
    Enum.find(projects, &(&1.slug == slug))
  end

  defp find_project_by_slug(_projects, _slug), do: nil

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

  defp pad_attempt(num) when is_integer(num) do
    num |> Integer.to_string() |> String.pad_leading(4, "0")
  end

  defp pad_attempt(_), do: "0001"

  defp format_time(nil), do: "—"

  defp format_time(time_str) when is_binary(time_str) do
    case DateTime.from_iso8601(time_str) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> time_str
    end
  end

  defp format_time(_), do: "—"

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
    project = socket.assigns.current_project

    if project do
      push_navigate(socket,
        to: ~p"/projects/#{project.slug}/stories/#{story_id}?tab=runs"
      )
    else
      socket
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
    project_root = derive_project_root(project)

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
  end

  defp load_run_detail_for_attempt(nil, _story_id, _attempt, _tab), do: nil
  defp load_run_detail_for_attempt(_project, nil, _attempt, _tab), do: nil

  defp load_run_detail_for_attempt(project, story_id, attempt, tab) do
    project_root = derive_project_root(project)
    parsed = parse_attempt(attempt)

    if parsed do
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
    end
  end

  defp derive_project_root(project) do
    cond do
      is_binary(project.local_path) and String.trim(project.local_path) != "" ->
        Path.expand(project.local_path)

      true ->
        File.cwd!()
    end
  end

  defp read_log_tab_content(files, tab) when is_map(files) and is_binary(tab) do
    file_path = Map.get(files, String.to_atom(tab))

    case file_path && File.read(file_path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  end

  defp read_log_tab_content(_files, _tab), do: nil

  defp fetch_orchestrator_status do
    Kollywood.Orchestrator.status()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp time_ago(nil), do: "never"

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
