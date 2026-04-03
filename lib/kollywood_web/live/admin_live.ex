defmodule KollywoodWeb.AdminLive do
  @moduledoc """
  Admin dashboard — service config, orchestrator controls, and managed repos.
  """
  use KollywoodWeb, :live_view

  alias Kollywood.Projects
  alias Kollywood.RepoSync
  alias Kollywood.RunQueue
  alias Kollywood.ServiceConfig
  alias Kollywood.WorkerConsumer

  @refresh_interval_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@refresh_interval_ms, self(), :refresh)
      RunQueue.subscribe()
    end

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:active_tab, :overview)
     |> assign(:selected_worker, nil)
     |> assign(:orchestrator_status, fetch_orchestrator_status())
     |> assign(:projects, Projects.list_projects())
     |> assign(:sync_status, %{})
     |> assign(:workers, list_workers())
     |> assign(:queue_stats, RunQueue.queue_overview_stats())
     |> assign(:recent_queue_entries, list_recent_queue_entries())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      case socket.assigns.live_action do
        :workers ->
          socket
          |> assign(:active_tab, :workers)
          |> assign(:selected_worker, nil)

        :worker_detail ->
          worker = find_worker(params["worker_id"])

          socket
          |> assign(:active_tab, :workers)
          |> assign(:selected_worker, worker)

        _other ->
          socket
          |> assign(:active_tab, :overview)
          |> assign(:selected_worker, nil)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, refresh_assigns(socket)}
  end

  def handle_info({:run_queue, _event}, socket) do
    {:noreply, refresh_assigns(socket)}
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
        <nav class="tabs tabs-boxed bg-base-200 inline-flex" aria-label="Admin navigation">
          <.link
            patch={~p"/admin"}
            class={[
              "tab",
              if(@active_tab == :overview, do: "tab-active")
            ]}
          >
            Overview
          </.link>
          <.link
            patch={~p"/admin/workers"}
            class={[
              "tab",
              if(@active_tab == :workers, do: "tab-active")
            ]}
          >
            Workers
          </.link>
        </nav>

        <%= if @active_tab == :overview do %>
          <.version_section />
          <.service_config_section />
          <.orchestrator_section status={@orchestrator_status} />
          <.repos_section
            projects={@projects}
            sync_status={@sync_status}
            orchestrator_status={@orchestrator_status}
          />
        <% else %>
          <.workers_section workers={@workers} selected_worker={@selected_worker} />
          <.queue_overview_section stats={@queue_stats} recent_entries={@recent_queue_entries} />
        <% end %>
      </main>
    </div>
    """
  end

  # --- Version ---

  defp version_section(assigns) do
    assigns =
      assigns
      |> assign(:version, Kollywood.Version.full())
      |> assign(:git_sha, Kollywood.Version.git_sha())
      |> assign(:build_time, Kollywood.Version.build_time())
      |> assign(:otp_release, :erlang.system_info(:otp_release) |> to_string())
      |> assign(:elixir_version, System.version())
      |> assign(:beam_pid, :os.getpid() |> to_string())

    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3">System</h2>
      <div class="card bg-base-200 border border-base-300">
        <div class="card-body p-4">
          <div class="flex flex-wrap gap-x-6 gap-y-2 text-sm">
            <div>
              <span class="text-base-content/60">Version</span>
              <span class="font-mono font-medium ml-1">{@version}</span>
            </div>
            <div>
              <span class="text-base-content/60">Built</span>
              <span class="font-mono text-xs ml-1">{@build_time}</span>
            </div>
            <div>
              <span class="text-base-content/60">OTP</span>
              <span class="font-mono ml-1">{@otp_release}</span>
            </div>
            <div>
              <span class="text-base-content/60">Elixir</span>
              <span class="font-mono ml-1">{@elixir_version}</span>
            </div>
            <div>
              <span class="text-base-content/60">BEAM PID</span>
              <span class="font-mono ml-1">{@beam_pid}</span>
            </div>
          </div>
        </div>
      </div>
    </section>
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
                    label="Server max agents (hard cap)"
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

  # --- Workers ---

  attr :workers, :list, required: true
  attr :selected_worker, :map, default: nil

  defp workers_section(assigns) do
    ~H"""
    <section>
      <div class="flex items-center justify-between mb-3">
        <h2 class="text-lg font-semibold">Workers</h2>
        <span class="text-xs text-base-content/60">{length(@workers)} detected</span>
      </div>

      <div class="card bg-base-200 border border-base-300">
        <div class="card-body p-0">
          <div class="overflow-x-auto">
            <table class="table table-sm" id="workers-list">
              <thead>
                <tr>
                  <th>Worker</th>
                  <th>Status</th>
                  <th>Node</th>
                  <th>Active</th>
                  <th>Last poll</th>
                  <th>Uptime</th>
                </tr>
              </thead>
              <tbody>
                <%= if @workers == [] do %>
                  <tr>
                    <td colspan="6" class="text-sm text-base-content/60">No workers detected.</td>
                  </tr>
                <% else %>
                  <%= for worker <- @workers do %>
                    <tr>
                      <td>
                        <.link
                          patch={~p"/admin/workers/#{worker.id}"}
                          class="font-mono text-sm hover:text-primary"
                        >
                          {worker.id}
                        </.link>
                      </td>
                      <td>
                        <span class={worker_status_badge_class(worker.status)}>{worker.status}</span>
                      </td>
                      <td class="font-mono text-xs">{worker.node_id || "—"}</td>
                      <td>{worker.active_workers}/{worker.max_local_workers}</td>
                      <td class="text-xs">{format_datetime(worker.last_poll_at)}</td>
                      <td class="text-xs">{format_duration_ms(worker.uptime_ms)}</td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <.worker_detail_panel :if={@selected_worker} worker={@selected_worker} />
    </section>
    """
  end

  attr :worker, :map, required: true

  defp worker_detail_panel(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 mt-6" id="worker-detail">
      <div class="card-body p-4 space-y-4">
        <div class="flex items-center justify-between">
          <h3 class="font-medium text-sm">Worker Detail: {@worker.id}</h3>
          <.link patch={~p"/admin/workers"} class="btn btn-xs btn-outline">Back to workers</.link>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4 text-sm">
          <div>
            <div class="text-base-content/60">Poll frequency</div>
            <div class="font-medium">{worker_poll_frequency_label(@worker)}</div>
          </div>
          <div>
            <div class="text-base-content/60">Claim success rate</div>
            <div class="font-medium">{claim_success_rate_label(@worker)}</div>
          </div>
          <div>
            <div class="text-base-content/60">Last seen</div>
            <div class="font-medium">{format_datetime(@worker.last_seen_at)}</div>
          </div>
          <div>
            <div class="text-base-content/60">Started at</div>
            <div class="font-medium">{format_datetime(@worker.started_at)}</div>
          </div>
        </div>

        <div>
          <h4 class="font-medium text-sm mb-2">Active runs</h4>
          <div class="overflow-x-auto">
            <table class="table table-sm" id="worker-active-runs">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Status</th>
                  <th>Started</th>
                  <th>Duration</th>
                  <th>Queue entry</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= if @worker.active_runs == [] do %>
                  <tr>
                    <td colspan="6" class="text-sm text-base-content/60">No active runs.</td>
                  </tr>
                <% else %>
                  <%= for run <- @worker.active_runs do %>
                    <tr>
                      <td>
                        <div class="font-mono text-xs">{run.issue_id}</div>
                        <div class="text-xs text-base-content/60">
                          {run.issue_title || run.identifier || "—"}
                        </div>
                      </td>
                      <td>
                        <span class="badge badge-sm badge-ghost capitalize">{run.status}</span>
                      </td>
                      <td class="text-xs">
                        {format_datetime(run.run_started_at || run.claimed_at || run.started_at)}
                      </td>
                      <td class="text-xs">
                        {format_duration_ms(
                          duration_since(run.run_started_at || run.claimed_at || run.started_at)
                        )}
                      </td>
                      <td class="font-mono text-xs">#{run.queue_entry_id}</td>
                      <td>
                        <.link
                          :if={run.project_slug}
                          navigate={run_detail_path(run)}
                          class="btn btn-xs btn-outline"
                        >
                          Run detail
                        </.link>
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :stats, :map, required: true
  attr :recent_entries, :list, required: true

  defp queue_overview_section(assigns) do
    ~H"""
    <section>
      <h2 class="text-lg font-semibold mb-3">Run Queue Overview</h2>

      <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4" id="run-queue-stats">
        <.queue_stat_card title="Pending" value={@stats.pending_count} />
        <.queue_stat_card title="Running" value={@stats.running_count} />
        <.queue_stat_card title="Completed (1h)" value={@stats.completed_last_hour_count} />
        <.queue_stat_card title="Failed (1h)" value={@stats.failed_last_hour_count} />
      </div>

      <div class="card bg-base-200 border border-base-300">
        <div class="card-body p-4">
          <h3 class="font-medium text-sm mb-2">Recent queue entries</h3>
          <div class="overflow-x-auto">
            <table class="table table-sm" id="recent-queue-entries">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Issue</th>
                  <th>Status</th>
                  <th>Node</th>
                  <th>Inserted</th>
                </tr>
              </thead>
              <tbody>
                <%= for entry <- @recent_entries do %>
                  <tr>
                    <td class="font-mono text-xs">#{entry.id}</td>
                    <td class="font-mono text-xs">{entry.issue_id}</td>
                    <td>
                      <span class={queue_status_badge_class(entry.status)}>{entry.status}</span>
                    </td>
                    <td class="font-mono text-xs">{entry.claimed_by_node || "—"}</td>
                    <td class="text-xs">{format_datetime(entry.inserted_at)}</td>
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

  attr :title, :string, required: true
  attr :value, :integer, required: true

  defp queue_stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body p-3">
        <div class="text-xs text-base-content/60">{@title}</div>
        <div class="text-xl font-semibold">{@value}</div>
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
                          {"workflow"}
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

  defp refresh_assigns(socket) do
    worker_id = socket.assigns[:selected_worker] && socket.assigns.selected_worker.id

    workers = list_workers()

    socket
    |> assign(:orchestrator_status, fetch_orchestrator_status())
    |> assign(:workers, workers)
    |> assign(:queue_stats, RunQueue.queue_overview_stats())
    |> assign(:recent_queue_entries, list_recent_queue_entries())
    |> assign(:selected_worker, if(worker_id, do: find_worker(worker_id, workers), else: nil))
  end

  defp list_workers do
    worker_names = discover_worker_names()

    Enum.map(worker_names, fn worker_name ->
      status = safe_worker_status(worker_name)
      worker_id = worker_name_to_id(worker_name)

      %{
        id: worker_id,
        node_id: status[:node_id],
        active_workers: status[:active_workers] || 0,
        max_local_workers: status[:max_local_workers] || 0,
        last_poll_at: status[:last_poll_at],
        started_at: status[:started_at],
        last_seen_at: status[:last_seen_at],
        uptime_ms: status[:uptime_ms],
        poll_interval_ms: status[:poll_interval_ms],
        poll_count: status[:poll_count] || 0,
        claim_attempts: status[:claim_attempts] || 0,
        claims_succeeded: status[:claims_succeeded] || 0,
        claim_success_rate: status[:claim_success_rate],
        active_runs: status[:active_runs] || [],
        status: worker_status_label(status)
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp find_worker(worker_id, workers \\ nil)

  defp find_worker(worker_id, workers) when is_binary(worker_id) and is_list(workers) do
    Enum.find(workers, &(&1.id == worker_id))
  end

  defp find_worker(worker_id, _workers) when is_binary(worker_id) do
    Enum.find(list_workers(), &(&1.id == worker_id))
  end

  defp find_worker(_, _), do: nil

  defp discover_worker_names do
    configured =
      if Application.get_env(:kollywood, :worker_consumer_enabled, true) do
        count = Application.get_env(:kollywood, :worker_consumer_count, 1)

        for i <- 1..count do
          String.to_atom("Elixir.Kollywood.WorkerConsumer.#{i}")
        end
      else
        []
      end

    registered =
      Process.registered()
      |> Enum.filter(fn atom ->
        atom_name = Atom.to_string(atom)

        atom_name == "Elixir.Kollywood.WorkerConsumer" or
          String.starts_with?(atom_name, "Elixir.Kollywood.WorkerConsumer.")
      end)

    (configured ++ registered)
    |> Enum.uniq()
  end

  defp safe_worker_status(worker_name) do
    WorkerConsumer.status(worker_name)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp worker_name_to_id(worker_name) when is_atom(worker_name),
    do: worker_name |> Atom.to_string() |> normalize_worker_id()

  defp worker_name_to_id(worker_name) when is_binary(worker_name),
    do: normalize_worker_id(worker_name)

  defp worker_name_to_id(_worker_name), do: "unknown"

  defp normalize_worker_id("Elixir." <> rest), do: rest
  defp normalize_worker_id(value), do: value

  defp worker_status_label(status) when is_map(status) do
    cond do
      status == %{} -> "stale"
      (status[:active_workers] || 0) > 0 -> "busy"
      stale_worker?(status) -> "stale"
      true -> "idle"
    end
  end

  defp worker_status_label(_status), do: "stale"

  defp stale_worker?(status) do
    with %DateTime{} = last_seen <- status[:last_seen_at],
         poll_ms when is_integer(poll_ms) and poll_ms > 0 <- status[:poll_interval_ms] do
      age_ms = DateTime.diff(DateTime.utc_now(), last_seen, :millisecond)
      age_ms > poll_ms * 3
    else
      _ -> false
    end
  end

  defp list_recent_queue_entries do
    RunQueue.list_recent(12)
  end

  defp format_datetime(nil), do: "—"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  end

  defp format_datetime(_), do: "—"

  defp format_duration_ms(ms) when is_integer(ms) and ms >= 0 do
    cond do
      ms < 1_000 -> "#{ms}ms"
      ms < 60_000 -> "#{div(ms, 1_000)}s"
      ms < 3_600_000 -> "#{div(ms, 60_000)}m"
      true -> "#{div(ms, 3_600_000)}h"
    end
  end

  defp format_duration_ms(_), do: "—"

  defp duration_since(%DateTime{} = dt), do: DateTime.diff(DateTime.utc_now(), dt, :millisecond)
  defp duration_since(_), do: nil

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

  defp worker_status_badge_class("busy"), do: "badge badge-sm badge-warning"
  defp worker_status_badge_class("stale"), do: "badge badge-sm badge-error"
  defp worker_status_badge_class(_), do: "badge badge-sm badge-success"

  defp queue_status_badge_class("running"), do: "badge badge-sm badge-info"
  defp queue_status_badge_class("claimed"), do: "badge badge-sm badge-warning"
  defp queue_status_badge_class("completed"), do: "badge badge-sm badge-success"
  defp queue_status_badge_class("failed"), do: "badge badge-sm badge-error"
  defp queue_status_badge_class("pending"), do: "badge badge-sm badge-ghost"
  defp queue_status_badge_class("cancelled"), do: "badge badge-sm badge-neutral"
  defp queue_status_badge_class(_), do: "badge badge-sm"

  defp worker_poll_frequency_label(worker) do
    poll_interval = worker.poll_interval_ms

    cond do
      is_integer(poll_interval) and poll_interval > 0 -> "#{poll_interval}ms"
      true -> "—"
    end
  end

  defp claim_success_rate_label(worker) do
    case worker.claim_success_rate do
      rate when is_float(rate) -> "#{Float.round(rate * 100, 1)}%"
      _ -> "—"
    end
  end

  defp run_detail_path(run) do
    attempt = run.attempt

    if is_integer(attempt) and attempt > 0 do
      ~p"/projects/#{run.project_slug}/runs/#{run.issue_id}/#{attempt}"
    else
      ~p"/projects/#{run.project_slug}/runs/#{run.issue_id}"
    end
  end
end
