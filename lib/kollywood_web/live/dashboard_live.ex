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

            <%!-- Theme Toggle --%>
            <.theme_toggle />
          </div>
        </header>

        <%= if @current_project do %>
          <%!-- Project Navigation --%>
          <nav class="bg-base-100 border-b border-base-300 px-4 sm:px-6 lg:px-8">
            <div class="flex gap-1 overflow-x-auto">
              <.nav_link
                active={@live_action == :overview}
                navigate={~p"/projects/#{@current_project.slug}"}
              >
                <.icon name="hero-squares-2x2" class="size-4" />
                Overview
              </.nav_link>

              <.nav_link
                active={@live_action == :stories}
                navigate={~p"/projects/#{@current_project.slug}/stories"}
              >
                <.icon name="hero-list-bullet" class="size-4" />
                Stories
              </.nav_link>

              <.nav_link
                active={@live_action == :runs}
                navigate={~p"/projects/#{@current_project.slug}/runs"}
              >
                <.icon name="hero-play" class="size-4" />
                Runs
              </.nav_link>

              <.nav_link
                active={@live_action == :settings}
                navigate={~p"/projects/#{@current_project.slug}/settings"}
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
                Settings
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
              <p class="text-base-content/70 mb-6">Choose a project from the dropdown to view its dashboard</p>
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
  attr :navigate, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2 px-4 py-3 text-sm font-medium border-b-2 transition-colors whitespace-nowrap",
        "hover:text-base-content",
        @active && "border-primary text-primary",
        !@active && "border-transparent text-base-content/70 hover:border-base-300"
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
    ~H