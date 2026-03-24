defmodule KollywoodWeb.DashboardLive do
  @moduledoc """
  Project-scoped dashboard LiveView with navigation, project selector,
  and overview counters for the selected project.
  """
  use KollywoodWeb, :live_view

  alias Kollywood.Projects
  alias Kollywood.Projects.Project

  @impl true
  def mount(params, _session, socket) do
    projects = Projects.list_enabled_projects()
    current_project = find_project_by_slug(projects, params["project_slug"])

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:current_project, current_project)
      |> assign(:current_scope, nil)
      |> assign_project_counters(current_project)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, uri, socket) do
    project_slug = params["project_slug"]
    current_project = find_project_by_slug(socket.assigns.projects, project_slug)

    socket =
      socket
      |> assign(:current_uri, uri)
      |> assign(:current_project, current_project)
      |> maybe_update_counters(current_project, socket.assigns.current_project)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_project", %{"project_slug" => slug}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects/#{slug}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-base-100">
        <%!-- Dashboard Header with Project Selector --%>
        <header class="navbar bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8">
          <div class="flex-1 flex items-center gap-4">
            <.link navigate={~p"/"} class="flex items-center gap-2">
              <.icon name="hero-rocket-launch" class="size-6 text-primary" />
              <span class="text-xl font-bold">Kollywood</span>
            </.link>
          </div>

          <div class="flex-none flex items-center gap-4">
            <%!-- Project Selector --%>
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
                      class={[
                        "flex items-center justify-between",
                        @current_project && @current_project.id == project.id && "bg-base-200"
                      ]}
                    >
                      <span class="truncate">{project.name}</span>
                      <%= if @current_project && @current_project.id == project.id do %>
                        <.icon name="hero-check" class="size-4 text-success" />
                      <% end %>
                    </.link>
                  </li>
                <% end %>
                <%= if @projects == [] do %>
                  <li class="text-base-content/50 text-sm px-3 py-2">No projects available</li>
                <% end %>
              </ul>
            </div>

            <%!-- Theme Toggle from Layout --%>
          </div>
        </header>

        <%= if @current_project do %>
          <%!-- Project Navigation --%>
          <nav class="bg-base-100 border-b border-base-300 px-4 sm:px-6 lg:px-8">
            <div class="flex gap-1 overflow-x-auto">
              <.nav_link
                active={@live_action == :overview}
                patch={~p"/projects/#{@current_project.slug}"}
              >
                <.icon name="hero-squares-2x2" class="size-4" /> Overview
              </.nav_link>

              <.nav_link
                active={@live_action == :stories}
                navigate={~p"/projects/#{@current_project.slug}/stories"}
              >
                <.icon name="hero-list-bullet" class="size-4" /> Stories
              </.nav_link>

              <.nav_link
                active={@live_action == :runs}
                navigate={~p"/projects/#{@current_project.slug}/runs"}
              >
                <.icon name="hero-play" class="size-4" /> Runs
              </.nav_link>

              <.nav_link
                active={@live_action == :settings}
                navigate={~p"/projects/#{@current_project.slug}/settings"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" /> Settings
              </.nav_link>
            </div>
          </nav>

          <%!-- Main Content Area --%>
          <main class="px-4 sm:px-6 lg:px-8 py-6">
            <div class="max-w-7xl mx-auto">
              <%= case @live_action do %>
                <% :overview -> %>
                  <.overview_section
                    project={@current_project}
                    counters={@counters}
                    active_workers={@active_workers}
                    last_errors={@last_errors}
                  />
                <% :stories -> %>
                  <.stories_section project={@current_project} />
                <% :runs -> %>
                  <.runs_section project={@current_project} />
                <% :settings -> %>
                  <.settings_section project={@current_project} />
                <% _ -> %>
                  <.overview_section
                    project={@current_project}
                    counters={@counters}
                    active_workers={@active_workers}
                    last_errors={@last_errors}
                  />
              <% end %>
            </div>
          </main>
        <% else %>
          <%!-- No Project Selected State --%>
          <main class="flex-1 flex items-center justify-center px-4">
            <div class="text-center">
              <.icon name="hero-folder-open" class="size-16 text-base-300 mx-auto mb-4" />
              <h2 class="text-xl font-semibold mb-2">Select a Project</h2>
              <p class="text-base-content/70 mb-6">
                Choose a project from the dropdown to view its dashboard
              </p>
              <%= if @projects == [] do %>
                <.button navigate={~p"/projects/new"}>Create Your First Project</.button>
              <% end %>
            </div>
          </main>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # -- Navigation Link Component --

  attr :active, :boolean, default: false
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      navigate={@navigate}
      class={[
        "flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap",
        "hover:text-base-content",
        assigns[:active] && "border-primary text-primary",
        !assigns[:active] && "border-transparent text-base-content/70 hover:border-base-300"
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # -- Overview Section Component --

  attr :project, Project, required: true
  attr :counters, :map, required: true
  attr :active_workers, :list, default: []
  attr :last_errors, :list, default: []

  defp overview_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Counter Cards --%>
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
        <.counter_card
          title="Open"
          value={@counters.open}
          icon="hero-circle-stack"
          color="neutral"
        />
        <.counter_card
          title="In Progress"
          value={@counters.in_progress}
          icon="hero-arrow-path"
          color="primary"
        />
        <.counter_card
          title="Done"
          value={@counters.done}
          icon="hero-check-circle"
          color="success"
        />
        <.counter_card
          title="Failed"
          value={@counters.failed}
          icon="hero-x-circle"
          color="error"
        />
      </div>

      <%!-- Active Workers & Last Errors Grid --%>
      <div class="grid lg:grid-cols-2 gap-6">
        <%!-- Active Workers --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h3 class="card-title text-lg flex items-center gap-2">
              <.icon name="hero-bolt" class="size-5 text-primary" /> Active Workers
            </h3>
            <%= if @active_workers == [] do %>
              <p class="text-base-content/60 py-4">No active workers</p>
            <% else %>
              <div class="space-y-2 mt-2">
                <%= for worker <- @active_workers do %>
                  <div class="flex items-center justify-between p-3 bg-base-100 rounded-lg">
                    <div class="flex items-center gap-3">
                      <span class="loading loading-spinner loading-sm text-primary"></span>
                      <span class="font-medium truncate">{worker.issue_id}</span>
                    </div>
                    <span class="text-sm text-base-content/60">{worker.status}</span>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Last Errors --%>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h3 class="card-title text-lg flex items-center gap-2">
              <.icon name="hero-exclamation-triangle" class="size-5 text-error" /> Recent Errors
            </h3>
            <%= if @last_errors == [] do %>
              <p class="text-base-content/60 py-4">No recent errors</p>
            <% else %>
              <div class="space-y-2 mt-2">
                <%= for error <- @last_errors do %>
                  <div class="p-3 bg-error/10 border border-error/20 rounded-lg">
                    <div class="flex items-center gap-2 mb-1">
                      <span class="font-medium text-sm">{error.issue_id}</span>
                      <span class="text-xs text-base-content/50">{error.time}</span>
                    </div>
                    <p class="text-sm text-error truncate">{error.message}</p>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Project Info Card --%>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body">
          <h3 class="card-title text-lg flex items-center gap-2">
            <.icon name="hero-information-circle" class="size-5" /> Project Information
          </h3>
          <div class="grid sm:grid-cols-2 gap-4 mt-2">
            <div>
              <span class="text-sm text-base-content/60">Provider</span>
              <p class="font-medium capitalize">{@project.provider}</p>
            </div>
            <div>
              <span class="text-sm text-base-content/60">Default Branch</span>
              <p class="font-medium">{@project.default_branch}</p>
            </div>
            <%= if @project.repository do %>
              <div class="sm:col-span-2">
                <span class="text-sm text-base-content/60">Repository</span>
                <p class="font-medium truncate">{@project.repository}</p>
              </div>
            <% end %>
            <%= if @project.local_path do %>
              <div class="sm:col-span-2">
                <span class="text-sm text-base-content/60">Local Path</span>
                <p class="font-medium truncate">{@project.local_path}</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Counter Card Component --

  attr :title, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, default: "neutral"

  defp counter_card(assigns) do
    color_classes = %{
      "neutral" => "bg-neutral/10 text-neutral",
      "primary" => "bg-primary/10 text-primary",
      "success" => "bg-success/10 text-success",
      "error" => "bg-error/10 text-error"
    }

    assigns =
      assign(assigns, :color_class, Map.get(color_classes, assigns.color, "bg-neutral/10"))

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <div class="flex items-center justify-between">
          <div>
            <p class="text-sm text-base-content/60">{@title}</p>
            <p class="text-3xl font-bold">{@value}</p>
          </div>
          <div class={["p-3 rounded-xl", @color_class]}>
            <.icon name={@icon} class="size-6" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Stories Section Component --

  attr :project, Project, required: true

  defp stories_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-2xl font-bold">Stories</h2>
        <button class="btn btn-primary" disabled>New Story (Coming Soon)</button>
      </div>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body">
          <p class="text-base-content/60">Stories will be listed here.</p>
        </div>
      </div>
    </div>
    """
  end

  # -- Runs Section Component --

  attr :project, Project, required: true

  defp runs_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <h2 class="text-2xl font-bold">Runs</h2>
        <.button phx-click="trigger_run">Trigger Run</.button>
      </div>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body">
          <p class="text-base-content/60">Run history will be listed here.</p>
        </div>
      </div>
    </div>
    """
  end

  # -- Settings Section Component --

  attr :project, Project, required: true

  defp settings_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Project Settings</h2>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body space-y-4">
          <div>
            <label class="label">Project Name</label>
            <input type="text" value={@project.name} class="input input-bordered w-full" disabled />
          </div>
          <div>
            <label class="label">Slug</label>
            <input type="text" value={@project.slug} class="input input-bordered w-full" disabled />
          </div>
          <div>
            <label class="label">Provider</label>
            <input type="text" value={@project.provider} class="input input-bordered w-full" disabled />
          </div>
          <div class="pt-4">
            <.button disabled>Edit Project (Coming Soon)</.button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # -- Helper Functions --

  defp find_project_by_slug(projects, slug) when is_binary(slug) do
    Enum.find(projects, &(&1.slug == slug))
  end

  defp find_project_by_slug(_projects, _slug), do: nil

  defp assign_project_counters(socket, nil) do
    assign(socket,
      counters: %{open: 0, in_progress: 0, done: 0, failed: 0},
      active_workers: [],
      last_errors: []
    )
  end

  defp assign_project_counters(socket, project) do
    # Fetch counters from project's tracker data
    counters = fetch_project_counters(project)
    active_workers = fetch_active_workers(project)
    last_errors = fetch_last_errors(project)

    assign(socket,
      counters: counters,
      active_workers: active_workers,
      last_errors: last_errors
    )
  end

  defp maybe_update_counters(socket, new_project, current_project)
       when new_project != current_project do
    assign_project_counters(socket, new_project)
  end

  defp maybe_update_counters(socket, _new_project, _current_project), do: socket

  defp fetch_project_counters(project) do
    # Try to read stories from the project's tracker_path
    case read_project_stories(project) do
      {:ok, stories} ->
        %{
          open: count_by_status(stories, "open"),
          in_progress: count_by_status(stories, "in_progress"),
          done: count_by_status(stories, "done"),
          failed: count_by_status(stories, "failed")
        }

      _error ->
        %{open: 0, in_progress: 0, done: 0, failed: 0}
    end
  end

  defp read_project_stories(project) do
    tracker_path = project.tracker_path

    if is_binary(tracker_path) and File.exists?(tracker_path) do
      with {:ok, content} <- File.read(tracker_path),
           {:ok, decoded} <- Jason.decode(content) do
        stories = Map.get(decoded, "userStories", [])
        {:ok, stories}
      end
    else
      {:error, :no_tracker}
    end
  end

  defp count_by_status(stories, status) do
    Enum.count(stories, fn story ->
      story_status = Map.get(story, "status", "open")
      normalize_status(story_status) == status
    end)
  end

  defp normalize_status(status) do
    status
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(" ", "_")
    |> String.replace("-", "_")
  end

  defp fetch_active_workers(_project) do
    # Placeholder: This would query the orchestrator for active runs
    # For now, return empty list
    []
  end

  defp fetch_last_errors(_project) do
    # Placeholder: This would query the orchestrator for recent errors
    # For now, return empty list
    []
  end
end
