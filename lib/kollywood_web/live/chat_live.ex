defmodule KollywoodWeb.ChatLive do
  @moduledoc """
  Project-scoped ACP chat with multiple sessions per project.
  """

  use KollywoodWeb, :live_view

  alias Kollywood.Chat
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
      |> assign(:chat_sessions, [])
      |> assign(:chat_selected_session_id, nil)
      |> assign(:chat_selected_snapshot, nil)
      |> assign(:chat_input, "")
      |> assign(:chat_error, nil)
      |> assign(:chat_subscription_project_slug, nil)
      |> assign(:page_title, page_title(current_project))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    project_slug = params["project_slug"]
    current_project = find_project_by_slug(socket.assigns.projects, project_slug)
    selected_session_id = params["session"]

    socket =
      socket
      |> assign(:current_project, current_project)
      |> assign(:page_title, page_title(current_project))
      |> ensure_chat_subscription(current_project)
      |> load_chat_assigns(current_project, selected_session_id)

    {:noreply, socket}
  end

  @impl true
  def handle_info({event, project_slug, _session_id}, socket)
      when event in [:chat_session_created, :chat_session_deleted, :chat_session_updated] do
    socket =
      case socket.assigns[:current_project] do
        %Project{slug: ^project_slug} = project ->
          load_chat_assigns(socket, project, socket.assigns[:chat_selected_session_id])

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_chat_input", %{"message" => message}, socket)
      when is_binary(message) do
    {:noreply, assign(socket, :chat_input, message)}
  end

  def handle_event("new_chat", _params, socket) do
    case create_chat_session(socket) do
      {:ok, socket, session_id} ->
        project = socket.assigns.current_project
        {:noreply, push_patch(socket, to: chat_path(project.slug, session_id))}

      {:error, socket, reason} ->
        {:noreply, socket |> assign(:chat_error, reason) |> put_flash(:error, reason)}
    end
  end

  def handle_event("select_chat", %{"id" => session_id}, socket) when is_binary(session_id) do
    case socket.assigns[:current_project] do
      %Project{slug: slug} ->
        {:noreply, push_patch(socket, to: chat_path(slug, session_id))}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_chat", %{"id" => session_id}, socket) when is_binary(session_id) do
    project = socket.assigns.current_project

    with %Project{slug: slug} <- project,
         :ok <- Chat.delete_session(session_id) do
      socket =
        socket
        |> assign(:chat_error, nil)
        |> load_chat_assigns(project, nil)

      {:noreply,
       push_patch(socket, to: chat_path(slug, socket.assigns[:chat_selected_session_id]))}
    else
      {:error, reason} ->
        {:noreply, socket |> assign(:chat_error, reason) |> put_flash(:error, reason)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_chat", _params, socket) do
    case socket.assigns[:chat_selected_session_id] do
      session_id when is_binary(session_id) ->
        case Chat.cancel(session_id) do
          :ok ->
            {:noreply, socket |> assign(:chat_error, nil)}

          {:error, reason} ->
            {:noreply, socket |> assign(:chat_error, reason) |> put_flash(:error, reason)}
        end

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("send_chat", %{"message" => message}, socket) when is_binary(message) do
    prompt = String.trim(message)

    cond do
      prompt == "" ->
        {:noreply, socket}

      true ->
        with {:ok, socket, session_id} <- ensure_selected_session(socket),
             {:ok, _result} <- Chat.send_prompt(session_id, prompt) do
          project = socket.assigns.current_project

          socket =
            socket
            |> assign(:chat_error, nil)
            |> assign(:chat_input, "")
            |> load_chat_assigns(project, session_id)

          {:noreply, socket}
        else
          {:error, socket, reason} ->
            {:noreply, socket |> assign(:chat_error, reason) |> put_flash(:error, reason)}

          {:error, reason} ->
            {:noreply, socket |> assign(:chat_error, reason) |> put_flash(:error, reason)}
        end
    end
  end

  @impl true
  def render(assigns) do
    status = get_in(assigns, [:chat_selected_snapshot, :status]) || :idle
    messages = get_in(assigns, [:chat_selected_snapshot, :messages]) || []

    assigns =
      assigns
      |> assign(:chat_status, status)
      |> assign(:chat_messages, messages)

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
                    navigate={chat_path(project.slug, nil)}
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
              navigate={~p"/projects/#{@current_project.slug}"}
            />
            <.nav_tab
              label="Stories"
              icon="hero-list-bullet"
              navigate={~p"/projects/#{@current_project.slug}/stories"}
            />
            <.nav_tab
              label="Runs"
              icon="hero-play"
              navigate={~p"/projects/#{@current_project.slug}/runs"}
            />
            <.nav_tab
              label="Settings"
              icon="hero-cog-6-tooth"
              navigate={~p"/projects/#{@current_project.slug}/settings"}
            />
            <.nav_tab
              label="Chat"
              icon="hero-chat-bubble-left-right"
              navigate={chat_path(@current_project.slug, @chat_selected_session_id)}
              active={true}
            />
          </div>
        </nav>

        <main class="px-4 sm:px-6 lg:px-8 py-6">
          <div class="max-w-7xl mx-auto grid grid-cols-1 lg:grid-cols-[18rem_1fr] gap-4">
            <aside class="card bg-base-100 border border-base-300">
              <div class="card-body p-4 gap-3">
                <button type="button" phx-click="new_chat" class="btn btn-primary btn-sm">
                  <.icon name="hero-plus" class="size-4" /> New Chat
                </button>

                <div class="space-y-2 max-h-[65vh] overflow-y-auto">
                  <%= if @chat_sessions == [] do %>
                    <p class="text-sm text-base-content/60">No chats yet.</p>
                  <% else %>
                    <%= for session <- @chat_sessions do %>
                      <div class={[
                        "rounded-lg border p-2",
                        @chat_selected_session_id == session.id &&
                          "border-primary bg-primary/5",
                        @chat_selected_session_id != session.id && "border-base-300"
                      ]}>
                        <button
                          type="button"
                          phx-click="select_chat"
                          phx-value-id={session.id}
                          class="w-full text-left"
                        >
                          <p class="text-sm font-medium truncate">{session.title || session.id}</p>
                          <p class="text-xs text-base-content/60">
                            {session.status} • {format_timestamp(
                              session.updated_at || session.inserted_at
                            )}
                          </p>
                        </button>

                        <button
                          type="button"
                          phx-click="delete_chat"
                          phx-value-id={session.id}
                          class="btn btn-ghost btn-xs text-error mt-2"
                        >
                          Delete
                        </button>
                      </div>
                    <% end %>
                  <% end %>
                </div>
              </div>
            </aside>

            <section class="card bg-base-100 border border-base-300 min-h-[70vh]">
              <div class="card-body p-4 gap-4">
                <div class="flex items-center justify-between">
                  <h2 class="text-lg font-semibold">
                    <%= if @chat_selected_snapshot do %>
                      {@chat_selected_snapshot.title}
                    <% else %>
                      Project Chat
                    <% end %>
                  </h2>
                  <span class="badge badge-outline">{@chat_status}</span>
                </div>

                <%= if @chat_error do %>
                  <div class="alert alert-error">
                    <span>{@chat_error}</span>
                  </div>
                <% end %>

                <div class="flex-1 overflow-y-auto border border-base-300 rounded-lg p-3 space-y-3 bg-base-100/50 min-h-[22rem]">
                  <%= if @chat_messages == [] do %>
                    <p class="text-sm text-base-content/60">
                      Start a new chat and ask the agent to plan work or create stories.
                    </p>
                  <% else %>
                    <%= for message <- @chat_messages do %>
                      <div class={[
                        "rounded-lg border p-3",
                        message.role == "user" && "border-info/40 bg-info/5",
                        message.role == "assistant" && "border-success/40 bg-success/5"
                      ]}>
                        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-1">
                          {message.role}
                        </p>
                        <pre class="whitespace-pre-wrap break-words text-sm font-sans">{message.content}</pre>
                      </div>
                    <% end %>
                  <% end %>
                </div>

                <form phx-submit="send_chat" phx-change="change_chat_input" class="space-y-2">
                  <textarea
                    name="message"
                    class="textarea textarea-bordered w-full h-24"
                    placeholder="Ask the agent to plan a feature, break it into stories, or refine requirements..."
                  ><%= @chat_input %></textarea>

                  <div class="flex items-center gap-2">
                    <button type="submit" class="btn btn-primary btn-sm">Send</button>
                    <button
                      type="button"
                      phx-click="cancel_chat"
                      class="btn btn-outline btn-sm"
                      disabled={
                        @chat_selected_session_id == nil or
                          @chat_status not in [:running, :cancelling]
                      }
                    >
                      Cancel
                    </button>
                  </div>
                </form>
              </div>
            </section>
          </div>
        </main>
      <% else %>
        <main class="flex items-center justify-center px-4 py-32">
          <div class="text-center">
            <.icon name="hero-folder-open" class="size-16 text-base-content/20 mx-auto mb-4" />
            <h2 class="text-xl font-semibold mb-2">Project not found</h2>
            <p class="text-base-content/70 mb-6">The selected project does not exist.</p>
            <.link navigate={~p"/"} class="btn btn-primary">Back to Projects</.link>
          </div>
        </main>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false

  defp nav_tab(assigns) do
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
      <.icon name={@icon} class="size-4" />
      {@label}
    </.link>
    """
  end

  defp ensure_selected_session(socket) do
    case socket.assigns[:chat_selected_session_id] do
      session_id when is_binary(session_id) ->
        {:ok, socket, session_id}

      _other ->
        case create_chat_session(socket) do
          {:ok, socket, session_id} -> {:ok, socket, session_id}
          {:error, socket, reason} -> {:error, socket, reason}
        end
    end
  end

  defp create_chat_session(socket) do
    case socket.assigns[:current_project] do
      %Project{} = project ->
        with {:ok, cwd} <- resolve_chat_cwd(project),
             {:ok, session} <- Chat.create_session(project.slug, cwd) do
          socket =
            socket
            |> assign(:chat_error, nil)
            |> load_chat_assigns(project, session.id)

          {:ok, socket, session.id}
        else
          {:error, reason} -> {:error, socket, reason}
        end

      _other ->
        {:error, socket, "select a project before creating a chat"}
    end
  end

  defp load_chat_assigns(socket, nil, _selected_session_id) do
    socket
    |> assign(:chat_sessions, [])
    |> assign(:chat_selected_session_id, nil)
    |> assign(:chat_selected_snapshot, nil)
  end

  defp load_chat_assigns(socket, %Project{slug: slug}, selected_session_id) do
    sessions = Chat.list_sessions(slug)
    selected_session_id = resolve_selected_session_id(sessions, selected_session_id)

    selected_snapshot =
      case selected_session_id do
        id when is_binary(id) ->
          case Chat.get_snapshot(id) do
            {:ok, snapshot} -> snapshot
            {:error, _reason} -> nil
          end

        _other ->
          nil
      end

    socket
    |> assign(:chat_sessions, sessions)
    |> assign(:chat_selected_session_id, selected_session_id)
    |> assign(:chat_selected_snapshot, selected_snapshot)
  end

  defp resolve_selected_session_id([], _selected), do: nil

  defp resolve_selected_session_id(sessions, selected) when is_binary(selected) do
    if Enum.any?(sessions, &(&1.id == selected)) do
      selected
    else
      sessions |> List.first() |> Map.get(:id)
    end
  end

  defp resolve_selected_session_id(sessions, _selected) do
    sessions |> List.first() |> Map.get(:id)
  end

  defp ensure_chat_subscription(socket, nil) do
    maybe_unsubscribe_project(socket, socket.assigns[:chat_subscription_project_slug])
  end

  defp ensure_chat_subscription(socket, %Project{slug: slug}) do
    current = socket.assigns[:chat_subscription_project_slug]

    cond do
      not connected?(socket) ->
        assign(socket, :chat_subscription_project_slug, slug)

      current == slug ->
        socket

      true ->
        socket
        |> maybe_unsubscribe_project(current)
        |> subscribe_project(slug)
    end
  end

  defp subscribe_project(socket, slug) do
    Phoenix.PubSub.subscribe(Kollywood.PubSub, Chat.topic(slug))
    assign(socket, :chat_subscription_project_slug, slug)
  end

  defp maybe_unsubscribe_project(socket, slug) when is_binary(slug) do
    Phoenix.PubSub.unsubscribe(Kollywood.PubSub, Chat.topic(slug))
    assign(socket, :chat_subscription_project_slug, nil)
  end

  defp maybe_unsubscribe_project(socket, _slug), do: socket

  defp resolve_chat_cwd(%Project{} = project) do
    candidates =
      [project.repository, Projects.local_path(project)]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&Path.expand/1)

    case Enum.find(candidates, &File.dir?/1) do
      nil ->
        {:error, "no local project directory found for #{project.slug}"}

      path ->
        {:ok, path}
    end
  end

  defp find_project_by_slug(projects, slug) when is_binary(slug) do
    Enum.find(projects, &(&1.slug == slug))
  end

  defp find_project_by_slug(_projects, _slug), do: nil

  defp page_title(nil), do: "Project Chat"
  defp page_title(%Project{name: name}), do: "#{name} • Chat"

  defp chat_path(project_slug, nil), do: ~p"/projects/#{project_slug}/chat"

  defp chat_path(project_slug, session_id),
    do: ~p"/projects/#{project_slug}/chat?session=#{session_id}"

  defp format_timestamp(nil), do: "just now"

  defp format_timestamp(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_value), do: "just now"
end
