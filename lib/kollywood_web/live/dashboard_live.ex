defmodule KollywoodWeb.DashboardLive do
  @moduledoc """
  Project-scoped dashboard with navigation, real story/run data,
  and run detail with logs.
  """
  use KollywoodWeb, :live_view

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
      |> assign(:page_title, if(current_project, do: current_project.name, else: "Dashboard"))
      |> assign(:orchestrator_status, fetch_orchestrator_status())
      |> load_project_data(current_project)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    project_slug = params["project_slug"]
    current_project = find_project_by_slug(socket.assigns.projects, project_slug)

    socket =
      socket
      |> assign(:current_project, current_project)
      |> assign(:page_title, if(current_project, do: current_project.name, else: "Dashboard"))
      |> assign(:run_detail_story_id, params["story_id"])
      |> assign(:run_detail_attempt, parse_attempt(params["attempt"]))
      |> load_project_data(current_project)

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
              active={@live_action == :stories}
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
                <.overview_section counters={@counters} stories={@stories} orchestrator_status={@orchestrator_status} />
              <% :stories -> %>
                <.stories_section stories={@stories} project={@current_project} />
              <% :runs -> %>
                <.runs_section run_attempts={@run_attempts} project={@current_project} />
              <% :run_detail -> %>
                <.run_detail_section
                  run_detail={@run_detail}
                  story_id={@run_detail_story_id}
                  attempt={@run_detail_attempt}
                  project={@current_project}
                />
              <% :settings -> %>
                <.settings_section project={@current_project} />
              <% _ -> %>
                <.overview_section counters={@counters} stories={@stories} orchestrator_status={@orchestrator_status} />
            <% end %>
          </div>
        </main>
      <% else %>
        <main class="flex items-center justify-center px-4 py-32">
          <div class="text-center">
            <.icon name="hero-folder-open" class="size-16 text-base-300 mx-auto mb-4" />
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

      <%= if @stories != [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h3 class="card-title text-lg">Recent Activity</h3>
            <div class="space-y-2 mt-2">
              <%= for story <- Enum.take(Enum.filter(@stories, & &1["lastRun"] || &1["lastError"]), 5) do %>
                <div class="flex items-center gap-3 p-2 rounded-lg bg-base-100">
                  <.status_badge status={story["status"] || "open"} />
                  <div class="flex-1 min-w-0">
                    <span class="font-medium text-sm">{story["id"]}</span>
                    <span class="text-sm text-base-content/70 ml-2 truncate">{story["title"]}</span>
                  </div>
                  <%= if story["lastError"] do %>
                    <span class="text-xs text-error truncate max-w-xs">{truncate(story["lastError"], 60)}</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Stories Section --

  attr :stories, :list, required: true
  attr :project, Project, required: true

  defp stories_section(assigns) do
    groups = %{
      "in_progress" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "in_progress")),
      "open" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "open")),
      "done" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "done")),
      "failed" => Enum.filter(assigns.stories, &(normalize_status(&1["status"]) == "failed"))
    }

    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Stories</h2>

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
                <div class="card bg-base-200 border border-base-300">
                  <div class="card-body p-4">
                    <div class="flex items-start justify-between gap-4">
                      <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-2">
                          <span class="font-mono text-sm font-semibold text-primary">{story["id"]}</span>
                          <span class="font-medium">{story["title"]}</span>
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
                          <span class="badge badge-sm badge-ghost">attempt {story["lastAttempt"]}</span>
                        <% end %>
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
    </div>
    """
  end

  # -- Runs Section --

  attr :run_attempts, :list, required: true
  attr :project, Project, required: true

  defp runs_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Runs</h2>

      <%= if @run_attempts == [] do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body items-center text-center py-12">
            <.icon name="hero-play" class="size-12 text-base-300 mb-2" />
            <p class="text-base-content/60">No runs found. Runs appear here when the orchestrator dispatches stories.</p>
          </div>
        </div>
      <% else %>
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
                      patch={~p"/projects/#{@project.slug}/runs/#{run.story_id}/#{run.attempt}"}
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
    </div>
    """
  end

  # -- Run Detail Section --

  attr :run_detail, :map, default: nil
  attr :story_id, :string, default: nil
  attr :attempt, :integer, default: nil
  attr :project, Project, required: true

  defp run_detail_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link patch={~p"/projects/#{@project.slug}/runs"} class="btn btn-ghost btn-sm">
          ← Back to Runs
        </.link>
        <h2 class="text-2xl font-bold">{@story_id} · Attempt {@attempt}</h2>
      </div>

      <%= if @run_detail do %>
        <div class="grid lg:grid-cols-3 gap-4">
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm text-base-content/60">Status</h3>
              <.run_status_badge status={@run_detail["status"] || "unknown"} />
            </div>
          </div>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm text-base-content/60">Started</h3>
              <p class="text-sm">{@run_detail["started_at"] || "—"}</p>
            </div>
          </div>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4">
              <h3 class="font-semibold text-sm text-base-content/60">Ended</h3>
              <p class="text-sm">{@run_detail["ended_at"] || "—"}</p>
            </div>
          </div>
        </div>

        <%= if @run_detail["error"] do %>
          <div class="alert alert-error">
            <.icon name="hero-exclamation-circle" class="size-5" />
            <span>{@run_detail["error"]}</span>
          </div>
        <% end %>

        <div class="space-y-4">
          <%= for {label, key} <- [{"Run Log", "run_log"}, {"Worker Log", "worker_log"}, {"Reviewer Log", "reviewer_log"}, {"Checks Log", "checks_log"}] do %>
            <% content = @run_detail[key] %>
            <%= if content && content != "" do %>
              <div class="collapse collapse-arrow bg-base-200 border border-base-300">
                <input type="checkbox" checked={key == "run_log"} />
                <div class="collapse-title font-medium">{label}</div>
                <div class="collapse-content">
                  <pre class="text-xs leading-relaxed overflow-x-auto whitespace-pre-wrap bg-base-300 p-4 rounded-lg max-h-96 overflow-y-auto">{content}</pre>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      <% else %>
        <div class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Run not found for {@story_id} attempt {@attempt}.</span>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Settings Section --

  attr :project, Project, required: true

  defp settings_section(assigns) do
    ~H"""
    <div class="space-y-6">
      <h2 class="text-2xl font-bold">Project Settings</h2>
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
                <p class="font-medium font-mono text-sm">{@project.local_path}</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
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
      <div class="flex items-center gap-1.5 text-xs text-base-content/50" title={"Last polled: #{time_ago(@status.last_poll_at)}"}>
        <span class={[
          "size-2 rounded-full",
          @status.running_count > 0 && "bg-success animate-pulse",
          @status.running_count == 0 && @status.last_error == nil && "bg-base-content/30",
          @status.last_error != nil && "bg-error"
        ]}></span>
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
        @status.running_count == 0 && @status.last_error == nil && "bg-base-200 border-base-300 text-base-content/60",
        @status.last_error != nil && "bg-error/10 border-error/20 text-error"
      ]}>
        <span class={[
          "size-2 rounded-full shrink-0",
          @status.running_count > 0 && "bg-success animate-pulse",
          @status.running_count == 0 && @status.last_error == nil && "bg-base-content/30",
          @status.last_error != nil && "bg-error"
        ]}></span>

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

    if story_id && attempt do
      assign(socket, :run_detail, load_run_detail(project, story_id, attempt))
    else
      assign(socket, :run_detail, nil)
    end
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
            attempt_num = attempt_dir_name |> String.replace_prefix("attempt-", "") |> String.to_integer()
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

  defp load_run_detail(project, story_id, attempt) do
    attempt_dir = Path.join([run_logs_dir(project), story_id, "attempt-#{pad_attempt(attempt)}"])

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
  end

  defp run_logs_dir(project) do
    if is_binary(project.tracker_path) do
      project.tracker_path
      |> Path.dirname()
      |> Path.join(".kollywood/run_logs")
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

  defp truncate(str, max) when is_binary(str) and byte_size(str) > max do
    String.slice(str, 0, max) <> "…"
  end

  defp truncate(str, _max), do: str

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
