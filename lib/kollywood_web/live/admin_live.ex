defmodule KollywoodWeb.AdminLive do
  @moduledoc """
  Admin dashboard — service config, orchestrator controls, and managed repos.
  """
  use KollywoodWeb, :live_view

  alias Kollywood.Projects
  alias Kollywood.RepoSync
  alias Kollywood.ServiceConfig

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval_ms, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:orchestrator_status, fetch_orchestrator_status())
     |> assign(:projects, Projects.list_projects())
     |> assign(:sync_status, %{})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket, :orchestrator_status, fetch_orchestrator_status())}
  end

  def handle_info({:sync_done, slug, result}, socket) do
    label =
      case result do
        :ok -> {:ok, "Synced"}
        {:error, reason} -> {:error, reason}
      end

    {:noreply, update(socket, :sync_status, &Map.put(&1, slug, label))}
  end

  @impl true
  def handle_event("poll_now", _params, socket) do
    try do
      Kollywood.Orchestrator.poll_now()
      {:noreply, put_flash(socket, :info, "Poll triggered.")}
    catch
      :exit, _ -> {:noreply, put_flash(socket, :error, "Orchestrator not running.")}
    end
  end

  def handle_event("set_maintenance_mode", %{"mode" => mode}, socket) do
    message =
      case Kollywood.Orchestrator.set_maintenance_mode(mode) do
        :ok ->
          if mode == "drain" do
            {:info, "Maintenance drain enabled. New work is paused."}
          else
            {:info, "Maintenance drain disabled. Scheduling resumed."}
          end

        {:error, :invalid_mode} ->
          {:error, "Invalid maintenance mode: #{inspect(mode)}"}
      end

    socket =
      case message do
        {:info, text} -> put_flash(socket, :info, text)
        {:error, text} -> put_flash(socket, :error, text)
      end

    {:noreply, assign(socket, :orchestrator_status, fetch_orchestrator_status())}
  rescue
    _ ->
      {:noreply, put_flash(socket, :error, "Orchestrator not running.")}
  catch
    :exit, _ ->
      {:noreply, put_flash(socket, :error, "Orchestrator not running.")}
  end

  def handle_event("stop_issue", %{"id" => issue_id}, socket) do
    try do
      Kollywood.Orchestrator.stop_issue(issue_id)
    catch
      :exit, _ -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("sync_repo", %{"slug" => slug}, socket) do
    project = Enum.find(socket.assigns.projects, &(&1.slug == slug))
    local_path = project && Projects.local_path(project)

    if is_binary(local_path) and File.dir?(local_path) do
      parent = self()

      branch = project.default_branch || "main"

      Task.start(fn ->
        result = RepoSync.sync(local_path, branch)

        send(parent, {:sync_done, slug, result})
      end)

      {:noreply, update(socket, :sync_status, &Map.put(&1, slug, :syncing))}
    else
      {:noreply, put_flash(socket, :error, "No managed clone found for #{slug}.")}
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
          <span class="text-base-content/30 mx-1">/</span>
          <span class="font-medium">Admin</span>
        </div>
        <div class="flex-none">
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">Projects</.link>
        </div>
      </header>

      <main class="px-4 sm:px-6 lg:px-8 py-8 max-w-6xl mx-auto space-y-8">
        <.service_config_section />
        <.orchestrator_section status={@orchestrator_status} />
        <.repos_section
          projects={@projects}
          sync_status={@sync_status}
          orchestrator_status={@orchestrator_status}
        />
      </main>
    </div>
    """
  end

  # --- Service Config ---

  defp service_config_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3">Service Config</h2>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body p-4">
          <table class="table table-sm table-fixed w-full">
            <tbody>
              <.config_row label="Home" value={ServiceConfig.kollywood_home()} />
              <.config_row label="Repos" value={ServiceConfig.repos_dir()} />
              <.config_row label="Workspaces" value={ServiceConfig.workspaces_dir()} />
            </tbody>
          </table>
        </div>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp config_row(assigns) do
    ~H"""
    <tr>
      <td class="text-base-content/60 w-28 shrink-0">{@label}</td>
      <td class="max-w-0">
        <div class="font-mono text-sm truncate" title={@value}>{@value}</div>
      </td>
    </tr>
    """
  end

  # --- Orchestrator ---

  attr :status, :any, required: true

  defp orchestrator_section(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-semibold">Orchestrator</h2>
        <div :if={@status != nil} class="flex items-center gap-2">
          <button
            :if={maintenance_mode(@status) != :drain}
            phx-click="set_maintenance_mode"
            phx-value-mode="drain"
            class="btn btn-sm btn-warning btn-outline gap-2"
          >
            <.icon name="hero-pause" class="size-4" /> Start Drain
          </button>
          <button
            :if={maintenance_mode(@status) == :drain}
            phx-click="set_maintenance_mode"
            phx-value-mode="normal"
            class="btn btn-sm btn-success btn-outline gap-2"
          >
            <.icon name="hero-play" class="size-4" /> Resume Scheduling
          </button>
          <button phx-click="poll_now" class="btn btn-sm btn-outline gap-2">
            <.icon name="hero-arrow-path" class="size-4" /> Poll Now
          </button>
        </div>
      </div>

      <%= if @status == nil do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-4">
            <p class="text-base-content/50 text-sm">Orchestrator is not running.</p>
          </div>
        </div>
      <% else %>
        <div class="space-y-4">
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4">
              <h3 class="font-medium text-sm mb-2">Config</h3>
              <table class="table table-xs table-fixed w-full">
                <tbody>
                  <.config_row label="Poll interval" value={"#{@status.poll_interval_ms}ms"} />
                  <.config_row
                    label="Max agents (requested)"
                    value={"#{@status.max_concurrent_agents_requested}"}
                  />
                  <.config_row
                    label="Max agents (effective)"
                    value={"#{@status.max_concurrent_agents_effective}"}
                  />
                  <.config_row
                    label="Max agents (hard cap)"
                    value={"#{@status.max_concurrent_agents_hard_cap}"}
                  />
                  <.config_row
                    label="Maintenance mode"
                    value={maintenance_mode_label(@status)}
                  />
                  <.config_row
                    label="Dispatch paused"
                    value={if @status.dispatch_paused, do: "yes", else: "no"}
                  />
                  <.config_row
                    label="Drain ready"
                    value={if @status.drain_ready, do: "yes", else: "no"}
                  />
                  <.config_row
                    label="Retries"
                    value={if @status.retries_enabled, do: "enabled", else: "disabled"}
                  />
                  <.config_row
                    :if={@status.max_attempts}
                    label="Max attempts"
                    value={"#{@status.max_attempts}"}
                  />
                  <.config_row
                    :if={@status.last_poll_at}
                    label="Last poll"
                    value={format_datetime(@status.last_poll_at)}
                  />
                  <.config_row
                    label="Poll freshness"
                    value={watchdog_freshness_value(Map.get(@status, :watchdog, %{}))}
                  />
                  <.config_row
                    :if={watchdog_recovery_attempt_value(Map.get(@status, :watchdog, %{})) != nil}
                    label="Last recovery"
                    value={watchdog_recovery_attempt_value(Map.get(@status, :watchdog, %{}))}
                  />
                </tbody>
              </table>
            </div>
          </div>

          <.running_table :if={@status.running != []} running={@status.running} />
          <.retrying_table :if={@status.retrying != []} retrying={@status.retrying} />
          <.project_limits_table
            :if={Map.get(@status, :project_limits, []) != []}
            project_limits={Map.get(@status, :project_limits, [])}
          />
        </div>
      <% end %>
    </section>
    """
  end

  attr :project_limits, :list, required: true

  defp project_limits_table(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <h3 class="font-medium text-sm mb-2">Project Limits</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Project</th>
                <th>Configured</th>
                <th>Effective</th>
                <th>Running</th>
                <th>Retrying</th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @project_limits do %>
                <tr>
                  <td class="font-mono text-sm">{entry.project_slug}</td>
                  <td>{entry.configured_max_concurrent_agents || "global"}</td>
                  <td>{entry.effective_max_concurrent_agents}</td>
                  <td>{entry.running_count}</td>
                  <td>{entry.retry_count}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :running, :list, required: true

  defp running_table(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <h3 class="font-medium text-sm mb-2">Running</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Issue</th>
                <th>Attempt</th>
                <th>Runtime</th>
                <th>Started</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @running do %>
                <tr>
                  <td class="font-mono text-sm">{entry.identifier}</td>
                  <td>{entry.attempt}</td>
                  <td>
                    <span class="badge badge-sm badge-ghost capitalize">
                      {entry.runtime_process_state}
                    </span>
                  </td>
                  <td class="text-xs text-base-content/60">
                    {format_datetime(entry.started_at)}
                  </td>
                  <td>
                    <button
                      phx-click="stop_issue"
                      phx-value-id={entry.issue_id}
                      class="btn btn-xs btn-error btn-outline"
                    >
                      Stop
                    </button>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  attr :retrying, :list, required: true

  defp retrying_table(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-4">
        <h3 class="font-medium text-sm mb-2">Retrying</h3>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Issue</th>
                <th>Attempt</th>
                <th>Reason</th>
                <th>Due in</th>
              </tr>
            </thead>
            <tbody>
              <%= for entry <- @retrying do %>
                <tr>
                  <td class="font-mono text-sm">{entry.identifier}</td>
                  <td>{entry.attempt}</td>
                  <td class="text-xs text-base-content/60">{entry.reason}</td>
                  <td class="text-xs">{format_ms(entry.due_in_ms)}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  # --- Repos ---

  attr :projects, :list, required: true
  attr :sync_status, :map, required: true
  attr :orchestrator_status, :map, default: nil

  defp repos_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3">Managed Repos</h2>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body p-0">
          <div class="overflow-x-auto">
            <table class="table table-sm table-fixed w-full">
              <thead>
                <tr>
                  <th class="w-40">Project</th>
                  <th class="w-24">Provider</th>
                  <th class="w-48">Source</th>
                  <th class="w-48">Managed Clone</th>
                  <th class="w-36">Agent Limit</th>
                  <th class="w-28">Status</th>
                  <th class="w-16"></th>
                </tr>
              </thead>
              <tbody>
                <%= for project <- @projects do %>
                  <% local_path = Projects.local_path(project) %>
                  <% clone_exists = is_binary(local_path) and File.dir?(local_path) %>
                  <% sync = Map.get(@sync_status, project.slug) %>
                  <tr>
                    <td>
                      <.link
                        navigate={~p"/projects/#{project.slug}"}
                        class="font-medium hover:text-primary"
                      >
                        {project.name}
                      </.link>
                    </td>
                    <td>
                      <span class="badge badge-sm badge-outline capitalize">
                        {project.provider}
                      </span>
                    </td>
                    <td class="max-w-0 w-48">
                      <div
                        class="font-mono text-xs text-base-content/60 truncate"
                        title={project.repository || "—"}
                      >
                        {project.repository || "—"}
                      </div>
                    </td>
                    <td class="max-w-0 w-48">
                      <div
                        class="font-mono text-xs text-base-content/60 truncate"
                        title={local_path || "—"}
                      >
                        {local_path || "—"}
                      </div>
                    </td>
                    <td>
                      <div class="text-xs">
                        <span class="font-medium">
                          {project.max_concurrent_agents || "global"}
                        </span>
                        <span class="text-base-content/50"> / </span>
                        <span class="font-medium">
                          {effective_project_limit_label(@orchestrator_status, project)}
                        </span>
                      </div>
                    </td>
                    <td>
                      <%= cond do %>
                        <% sync == :syncing -> %>
                          <span class="flex items-center gap-1 text-xs text-base-content/60">
                            <span class="loading loading-spinner loading-xs"></span> Syncing…
                          </span>
                        <% match?({:ok, _}, sync) -> %>
                          <span class="badge badge-sm badge-success">Synced</span>
                        <% match?({:error, _}, sync) -> %>
                          <% {:error, reason} = sync %>
                          <span class="badge badge-sm badge-error" title={reason}>Error</span>
                        <% clone_exists -> %>
                          <span class="badge badge-sm badge-ghost">Cloned</span>
                        <% true -> %>
                          <span class="badge badge-sm badge-warning">Not cloned</span>
                      <% end %>
                    </td>
                    <td>
                      <button
                        :if={clone_exists}
                        phx-click="sync_repo"
                        phx-value-slug={project.slug}
                        disabled={sync == :syncing}
                        class="btn btn-xs btn-outline gap-1"
                      >
                        <.icon name="hero-arrow-path" class="size-3" /> Sync
                      </button>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </section>
    """
  end

  # --- Helpers ---

  defp fetch_orchestrator_status do
    Kollywood.Orchestrator.status()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(_), do: "—"

  defp format_ms(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_ms(ms) when is_integer(ms), do: "#{div(ms, 1000)}s"
  defp format_ms(_), do: "—"

  defp watchdog_freshness_value(watchdog) when is_map(watchdog) do
    stale = Map.get(watchdog, :stale, false)
    age_ms = format_ms(Map.get(watchdog, :age_ms))
    threshold_ms = format_ms(Map.get(watchdog, :threshold_ms))

    status = if stale, do: "stale", else: "healthy"
    "#{status} (age #{age_ms}, threshold #{threshold_ms})"
  end

  defp watchdog_freshness_value(_watchdog), do: "—"

  defp watchdog_recovery_attempt_value(watchdog) when is_map(watchdog) do
    case Map.get(watchdog, :last_recovery_attempt) do
      attempt when is_map(attempt) ->
        attempted_at = format_datetime(Map.get(attempt, :attempted_at))
        outcome = Map.get(attempt, :outcome) || "-"
        "#{attempted_at} (#{outcome})"

      _other ->
        nil
    end
  end

  defp watchdog_recovery_attempt_value(_watchdog), do: nil

  defp maintenance_mode(status) when is_map(status) do
    case Map.get(status, :maintenance_mode, :normal) do
      "drain" -> :drain
      :drain -> :drain
      _other -> :normal
    end
  end

  defp maintenance_mode(_status), do: :normal

  defp maintenance_mode_label(status) do
    case maintenance_mode(status) do
      :drain -> "drain (new work paused)"
      :normal -> "normal"
    end
  end

  defp effective_project_limit_label(%{} = status, project) when is_map(project) do
    project_slug = Map.get(project, :slug)

    status
    |> Map.get(:project_limits, [])
    |> Enum.find(fn entry -> Map.get(entry, :project_slug) == project_slug end)
    |> case do
      %{effective_max_concurrent_agents: limit} when is_integer(limit) ->
        Integer.to_string(limit)

      _other ->
        case Map.get(status, :max_concurrent_agents) do
          limit when is_integer(limit) and limit > 0 -> Integer.to_string(limit)
          _ -> "-"
        end
    end
  end

  defp effective_project_limit_label(_status, _project), do: "-"
end
