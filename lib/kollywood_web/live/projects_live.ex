defmodule KollywoodWeb.ProjectsLive do
  use KollywoodWeb, :live_view

  alias Kollywood.Projects
  alias Kollywood.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_projects()

    socket =
      socket
      |> assign(:projects, projects)
      |> assign(:current_scope, nil)
      |> assign(:page_title, "Projects")
      |> assign(:delete_confirm, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :new ->
          changeset = Projects.change_project(%Project{}, %{})

          socket
          |> assign(:page_title, "Add Project")
          |> assign(:form, to_form(changeset, as: "project"))
          |> assign(:selected_provider, "local")

        :index ->
          socket
          |> assign(:page_title, "Projects")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    existing_params = Map.merge(socket.assigns.form.params || %{}, %{"provider" => provider})

    changeset =
      %Project{}
      |> Projects.change_project(existing_params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:selected_provider, provider)
     |> assign(:form, to_form(changeset, as: "project"))}
  end

  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      %Project{}
      |> Projects.change_project(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "project"))}
  end

  def handle_event("save", %{"project" => params}, socket) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project \"#{project.name}\" created.")
         |> push_navigate(to: ~p"/projects/#{project.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "project"))}
    end
  end

  def handle_event("confirm_delete", %{"id" => id}, socket) do
    project = Projects.get_project!(id)
    {:noreply, assign(socket, :delete_confirm, project)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :delete_confirm, nil)}
  end

  def handle_event("delete_project", _params, socket) do
    project = socket.assigns.delete_confirm

    case Projects.delete_project(project) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project \"#{project.name}\" deleted.")
         |> assign(:delete_confirm, nil)
         |> assign(:projects, Projects.list_projects())}

      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete project.")
         |> assign(:delete_confirm, nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <header class="navbar bg-base-200 border-b border-base-300 px-4 sm:px-6 lg:px-8">
        <div class="flex-1 flex items-center gap-2">
          <.link navigate={~p"/"} class="flex items-center gap-2">
            <.icon name="hero-rocket-launch" class="size-6 text-primary" />
            <span class="text-xl font-bold">Kollywood</span>
          </.link>
        </div>
      </header>

      <main class="px-4 sm:px-6 lg:px-8 py-8">
        <div class="max-w-5xl mx-auto">
          <%= if @live_action == :new do %>
            <.add_project_form form={@form} selected_provider={@selected_provider} />
          <% else %>
            <.projects_index projects={@projects} />
          <% end %>

          <.delete_modal :if={@delete_confirm} project={@delete_confirm} />
        </div>
      </main>
    </div>
    """
  end

  # -- Projects Index --

  attr :projects, :list, required: true

  defp projects_index(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold">Projects</h1>
        <.link navigate={~p"/projects/new"} class="btn btn-primary btn-sm gap-2">
          <.icon name="hero-plus" class="size-4" /> Add Project
        </.link>
      </div>

      <%= if @projects == [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-16">
            <.icon name="hero-folder-open" class="size-16 text-base-300 mb-4" />
            <h2 class="text-xl font-semibold mb-2">No projects yet</h2>
            <p class="text-base-content/70 mb-6">Add a project to get started with Kollywood.</p>
            <.link navigate={~p"/projects/new"} class="btn btn-primary">Add Your First Project</.link>
          </div>
        </div>
      <% else %>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <%= for project <- @projects do %>
            <div class="card bg-base-200 border border-base-300 hover:border-primary/50 hover:shadow-lg transition-all relative">
              <.link navigate={~p"/projects/#{project.slug}"} class="card-body cursor-pointer">
                <h2 class="card-title text-lg pr-8">{project.name}</h2>
                <div class="flex items-center gap-2 text-sm text-base-content/60">
                  <span class="badge badge-sm badge-outline capitalize">{project.provider}</span>
                  <span>{project.default_branch}</span>
                </div>
                <%= if project.local_path do %>
                  <p class="text-xs text-base-content/40 truncate mt-1">{project.local_path}</p>
                <% end %>
                <%= if project.repository do %>
                  <p class="text-xs text-base-content/40 truncate mt-1">{project.repository}</p>
                <% end %>
                <div class="flex items-center gap-1 mt-2">
                  <span class={"badge badge-sm #{if project.enabled, do: "badge-success", else: "badge-ghost"}"}>
                    {if project.enabled, do: "Active", else: "Disabled"}
                  </span>
                </div>
              </.link>
              <button
                phx-click="confirm_delete"
                phx-value-id={project.id}
                class="btn btn-ghost btn-xs btn-square absolute top-3 right-3 text-base-content/40 hover:text-error"
                title="Delete project"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Add Project Form --

  attr :form, :any, required: true
  attr :selected_provider, :string, required: true

  defp add_project_form(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-4 mb-8">
        <.link navigate={~p"/"} class="btn btn-ghost btn-sm">← Back</.link>
        <h1 class="text-2xl font-bold">Add Project</h1>
      </div>

      <div class="card bg-base-200 border border-base-300 max-w-2xl">
        <div class="card-body">
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <.input field={@form[:name]} type="text" label="Project Name" placeholder="My Project" />

            <div class="fieldset mb-2">
              <label class="label mb-2">Provider</label>
              <div class="flex gap-2">
                <%= for {value, label, icon} <- [{"local", "Local", "hero-folder"}, {"github", "GitHub", "hero-globe-alt"}, {"gitlab", "GitLab", "hero-globe-alt"}] do %>
                  <button
                    type="button"
                    phx-click="select_provider"
                    phx-value-provider={value}
                    class={"btn btn-sm gap-2 #{if @selected_provider == value, do: "btn-primary", else: "btn-outline"}"}
                  >
                    <.icon name={icon} class="size-4" />
                    {label}
                  </button>
                <% end %>
              </div>
              <input type="hidden" name={@form[:provider].name} value={@selected_provider} />
            </div>

            <%= if @selected_provider == "local" do %>
              <.input
                field={@form[:local_path]}
                type="text"
                label="Local Path"
                placeholder="/home/user/projects/my-project"
              />
            <% else %>
              <.input
                field={@form[:repository]}
                type="text"
                label="Repository"
                placeholder={"#{if @selected_provider == "github", do: "owner/repo", else: "group/project"}"}
              />
            <% end %>

            <.input
              field={@form[:default_branch]}
              type="text"
              label="Default Branch"
              placeholder="main"
            />

            <div class="pt-4 flex gap-2">
              <button type="submit" class="btn btn-primary">Create Project</button>
              <.link navigate={~p"/"} class="btn btn-ghost">Cancel</.link>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # -- Delete Confirmation Modal --

  attr :project, Project, required: true

  defp delete_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="text-lg font-bold">Delete Project</h3>
        <p class="py-4">
          Are you sure you want to delete <strong>{@project.name}</strong>?
          This cannot be undone.
        </p>
        <div class="modal-action">
          <button phx-click="cancel_delete" class="btn btn-ghost">Cancel</button>
          <button phx-click="delete_project" class="btn btn-error">Delete</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_delete"></div>
    </div>
    """
  end
end
