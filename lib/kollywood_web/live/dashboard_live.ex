defmodule KollywoodWeb.DashboardLive do
  @moduledoc """
  Project-scoped dashboard with navigation, real story/run data,
  and run detail with logs.
  """
  use KollywoodWeb, :live_view
  require Logger

  alias Kollywood.Agent.CursorStreamLog
  alias Kollywood.Orchestrator.RunPhase
  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.ServiceConfig
  alias Kollywood.StoryExecutionOverrides
  alias Kollywood.StepRetry
  alias Kollywood.Tracker.PrdJson

  @default_stories_view "kanban"
  @story_status_columns [
    {"draft", "Draft"},
    {"open", "Open"},
    {"in_progress", "In Progress"},
    {"done", "Done"},
    {"merged", "Merged"},
    {"failed", "Failed"}
  ]
  @story_status_order Enum.map(@story_status_columns, fn {status, _label} -> status end)
  @agent_kind_options StoryExecutionOverrides.valid_agent_kind_strings()
  @log_tabs ["agent", "review_agent", "testing_agent", "worker"]
  @reports_tabs ["review", "testing"]

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
      |> assign(:settings_edit_mode, false)
      |> assign(:run_detail_panel_tab, "logs")
      |> assign(:run_view_tab, "steps")
      |> assign(:step_detail_tab, "logs")
      |> assign(:reports_tab, "review")
      |> assign(:active_prompt_tab, "agent")
      |> assign(:active_log_tab, "agent")
      |> assign(:artifact_preview, nil)
      |> assign(:action_confirmation, nil)
      |> assign(:preview_session, nil)
      |> assign(:step_idx, nil)
      |> assign(:current_step, nil)
      |> assign(:log_poll_timer, nil)
      |> assign(:story_form_mode, nil)
      |> assign(:story_form_values, %{})
      |> assign(:story_form_story_id, nil)
      |> assign(:story_form_error, nil)
      |> assign(:stories_view, @default_stories_view)
      |> assign(:collapsed_story_groups, MapSet.new())
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
    stories_view = resolve_stories_view(params["view"], socket.assigns[:stories_view])
    active_log_tab = resolve_active_log_tab(params["log_tab"], socket.assigns[:active_log_tab])

    socket =
      socket
      |> assign(:current_project, current_project)
      |> assign(:page_title, if(current_project, do: current_project.name, else: "Dashboard"))
      |> assign(:active_log_tab, active_log_tab)
      |> assign(:artifact_preview, nil)
      |> assign(:action_confirmation, nil)
      |> assign(:settings_edit_mode, false)
      |> assign(:run_detail_story_id, params["story_id"])
      |> assign(:run_detail_attempt, params["attempt"])
      |> assign(:stories_view, stories_view)
      |> assign(
        :collapsed_story_groups,
        Map.get(socket.assigns, :collapsed_story_groups, MapSet.new())
      )
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

  def handle_info(
        {:step_retry_finished, project_slug, story_id, source_attempt, retry_step, result},
        socket
      ) do
    socket =
      case socket.assigns[:current_project] do
        %Project{slug: ^project_slug} = project ->
          handle_step_retry_finished(
            socket,
            project,
            story_id,
            source_attempt,
            retry_step,
            result
          )

        _other ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(:poll_logs, socket) do
    tab = socket.assigns.active_log_tab
    run_detail = load_selected_run_detail(socket, tab)
    socket = assign(socket, :run_detail, run_detail)

    if run_detail && get_in(run_detail, ["metadata", "status"]) == "running" do
      {:noreply, socket}
    else
      {:noreply, cancel_poll_timer(socket)}
    end
  end

  @impl true
  def handle_event("set_log_tab", %{"tab" => tab}, socket) do
    next_tab = resolve_active_log_tab(tab, socket.assigns[:active_log_tab])
    run_detail = load_selected_run_detail(socket, next_tab)

    socket =
      socket
      |> assign(:active_log_tab, next_tab)
      |> assign(:run_detail, run_detail)
      |> assign(:artifact_preview, nil)
      |> maybe_patch_log_tab(next_tab)

    {:noreply, socket}
  end

  def handle_event("set_run_view_tab", %{"tab" => tab}, socket) do
    next_tab = if tab in ["steps", "settings"], do: tab, else: "steps"
    {:noreply, assign(socket, :run_view_tab, next_tab)}
  end

  def handle_event("set_step_detail_tab", %{"tab" => tab}, socket) do
    next_tab = if tab in ["logs", "prompt", "reports"], do: tab, else: "logs"
    {:noreply, assign(socket, :step_detail_tab, next_tab)}
  end

  def handle_event("set_run_detail_panel_tab", %{"tab" => tab}, socket) do
    next_tab = if tab in ["logs", "reports", "prompts", "settings"], do: tab, else: "logs"

    socket =
      socket
      |> assign(:run_detail_panel_tab, next_tab)
      |> assign(:artifact_preview, nil)

    {:noreply, socket}
  end

  def handle_event("set_reports_tab", %{"tab" => tab}, socket) do
    next_tab = resolve_reports_tab(tab, socket.assigns[:reports_tab])

    socket =
      socket
      |> assign(:reports_tab, next_tab)
      |> assign(:artifact_preview, nil)

    {:noreply, socket}
  end

  def handle_event("set_prompt_tab", %{"tab" => tab}, socket) do
    next_tab = if tab in ["agent", "review", "testing"], do: tab, else: "agent"
    {:noreply, assign(socket, :active_prompt_tab, next_tab)}
  end

  def handle_event("start_preview", %{"story_id" => story_id}, socket) do
    project = socket.assigns.current_project

    socket =
      case start_preview_for_story(project, story_id) do
        {:ok, session} ->
          socket
          |> assign(:preview_session, session)
          |> put_flash(:info, "Preview started.")

        {:error, reason} ->
          put_flash(socket, :error, "Preview failed: #{reason}")
      end

    {:noreply, socket}
  end

  def handle_event("stop_preview", %{"story_id" => story_id}, socket) do
    project = socket.assigns.current_project

    socket =
      if project do
        case Kollywood.PreviewSessionManager.stop_preview(project.slug, story_id) do
          :ok ->
            socket
            |> assign(:preview_session, nil)
            |> put_flash(:info, "Preview stopped.")

          {:error, reason} ->
            put_flash(socket, :error, "Stop preview failed: #{reason}")
        end
      else
        put_flash(socket, :error, "No project selected.")
      end

    {:noreply, socket}
  end

  def handle_event("merge_story", %{"story_id" => story_id}, socket) do
    project = socket.assigns.current_project

    socket =
      case merge_pending_story(project, story_id) do
        :ok ->
          Kollywood.PreviewSessionManager.stop_if_active(project.slug, story_id)

          socket
          |> assign(:preview_session, nil)
          |> load_project_data(project)
          |> sync_story_detail_selection()
          |> put_flash(:info, "Story merged successfully.")

        {:error, reason} ->
          put_flash(socket, :error, "Merge failed: #{reason}")
      end

    {:noreply, socket}
  end

  def handle_event("open_artifact_preview", %{"url" => url, "type" => type} = params, socket) do
    if valid_artifact_preview?(url, type) do
      preview = %{
        "url" => String.trim(url),
        "type" => String.downcase(type),
        "title" => params |> Map.get("title", "") |> to_string()
      }

      {:noreply, assign(socket, :artifact_preview, preview)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_artifact_preview", _params, socket) do
    {:noreply, assign(socket, :artifact_preview, nil)}
  end

  def handle_event("set_story_tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:story_detail_tab, tab) |> assign(:settings_edit_mode, false)}
  end

  def handle_event("toggle_settings_edit", _params, socket) do
    {:noreply, assign(socket, :settings_edit_mode, !socket.assigns.settings_edit_mode)}
  end

  def handle_event("save_story_overrides", %{"overrides" => params}, socket) do
    project = socket.assigns.current_project
    story_id = socket.assigns.run_detail_story_id

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          settings = build_override_settings(params)

          case PrdJson.update_story(tracker_path, story_id, %{"settings" => settings}) do
            {:ok, _story} ->
              socket
              |> load_project_data(project)
              |> sync_story_detail_selection()
              |> assign(:settings_edit_mode, false)
              |> put_flash(:info, "Execution overrides saved.")

            {:error, reason} ->
              put_flash(socket, :error, reason)
          end

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("set_stories_view", %{"view" => view}, socket) do
    stories_view = normalize_stories_view(view)

    socket =
      socket
      |> assign(:stories_view, stories_view)
      |> maybe_patch_stories_view(stories_view)

    {:noreply, socket}
  end

  def handle_event("toggle_story_group", %{"status" => status}, socket) do
    normalized_status = normalize_status(status)

    if normalized_status in @story_status_order do
      collapsed_story_groups =
        socket.assigns
        |> Map.get(:collapsed_story_groups, MapSet.new())
        |> toggle_collapsed_story_group(normalized_status)

      {:noreply, assign(socket, :collapsed_story_groups, collapsed_story_groups)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_story", _params, socket) do
    {:noreply, assign(socket, :selected_story, nil)}
  end

  def handle_event("update_story_status", %{"id" => id, "status" => status}, socket) do
    socket =
      case validate_manual_story_transition(socket.assigns.stories, id, nil, status) do
        {:ok, normalized_status} ->
          update_story_status(socket, id, normalized_status)

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("move_story_card", %{"id" => id, "to_status" => to_status} = params, socket) do
    from_status = Map.get(params, "from_status")

    socket =
      case validate_manual_story_transition(socket.assigns.stories, id, from_status, to_status) do
        {:ok, normalized_status} ->
          update_story_status(
            socket,
            id,
            normalized_status,
            "Moved #{id} to #{display_status(normalized_status)}."
          )

        {:error, reason} ->
          put_flash(socket, :error, reason)
      end

    {:noreply, socket}
  end

  def handle_event("reset_story", %{"id" => id, "confirmed" => confirmed} = _params, socket)
      when is_binary(id) do
    socket =
      if confirmed_action?(%{"confirmed" => confirmed}) do
        socket
        |> clear_action_confirmation()
        |> perform_reset_story(id)
      else
        open_reset_confirmation(socket, id)
      end

    {:noreply, socket}
  end

  def handle_event("reset_story", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, open_reset_confirmation(socket, id)}
  end

  def handle_event("reset_story", _params, socket) do
    {:noreply, put_flash(socket, :error, "Story ID is required.")}
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
    if project, do: Kollywood.PreviewSessionManager.stop_if_active(project.slug, story_id)

    socket =
      case local_tracker_path(project) do
        {:ok, tracker_path} ->
          case PrdJson.delete_story(tracker_path, story_id) do
            :ok ->
              cleanup_worktree(project, story_id)

              socket
              |> assign(:preview_session, nil)
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

  def handle_event("trigger_run", params, socket) do
    socket =
      if confirmed_action?(params) do
        socket
        |> clear_action_confirmation()
        |> perform_trigger_run(params)
      else
        open_retry_confirmation(socket, params)
      end

    {:noreply, socket}
  end

  def handle_event("cancel_action_confirmation", _params, socket) do
    {:noreply, clear_action_confirmation(socket)}
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
              git_commit_workflow(path)

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
                    navigate={project_overview_path(project.slug, @stories_view)}
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
              patch={project_overview_path(@current_project.slug, @stories_view)}
            />
            <.nav_tab
              label="Stories"
              icon="hero-list-bullet"
              active={@live_action in [:stories, :story_detail]}
              patch={stories_index_path(@current_project.slug, @stories_view)}
            />
            <.nav_tab
              label="Runs"
              icon="hero-play"
              active={@live_action in [:runs, :run_detail, :step_detail]}
              patch={project_runs_path(@current_project.slug, @stories_view)}
            />
            <.nav_tab
              label="Settings"
              icon="hero-cog-6-tooth"
              active={@live_action == :settings}
              patch={project_settings_path(@current_project.slug, @stories_view)}
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
                  stories_view={@stories_view}
                />
              <% :stories -> %>
                <.stories_section
                  stories={@stories}
                  project={@current_project}
                  stories_view={@stories_view}
                  collapsed_story_groups={@collapsed_story_groups}
                  run_attempts={@run_attempts}
                />
              <% :runs -> %>
                <.runs_section
                  run_attempts={@run_attempts}
                  project={@current_project}
                  stories={@stories}
                  stories_view={@stories_view}
                />
              <% :story_detail -> %>
                <.story_detail_section
                  story={@selected_story}
                  story_id={@run_detail_story_id}
                  run_detail={@run_detail}
                  run_detail_panel_tab={@run_detail_panel_tab}
                  reports_tab={@reports_tab}
                  active_prompt_tab={@active_prompt_tab}
                  active_log_tab={@active_log_tab}
                  story_detail_tab={@story_detail_tab}
                  settings_edit_mode={@settings_edit_mode}
                  project={@current_project}
                  stories_view={@stories_view}
                  story_attempts={Enum.filter(@run_attempts, &(&1.story_id == @run_detail_story_id))}
                  selected_attempt={@run_detail_attempt}
                  preview_session={@preview_session}
                />
              <% :run_detail -> %>
                <.run_steps_section
                  run_detail={@run_detail}
                  story_id={@run_detail_story_id}
                  attempt={@run_detail_attempt}
                  project={@current_project}
                  stories_view={@stories_view}
                  run_view_tab={@run_view_tab}
                />
              <% :step_detail -> %>
                <.step_detail_section
                  run_detail={@run_detail}
                  story_id={@run_detail_story_id}
                  attempt={@run_detail_attempt}
                  step_idx={@step_idx}
                  step={@current_step}
                  project={@current_project}
                  stories_view={@stories_view}
                  step_detail_tab={@step_detail_tab}
                />
              <% :settings -> %>
                <.settings_section
                  project={@current_project}
                  workflow={@workflow}
                  orchestrator_status={@orchestrator_status}
                  workflow_editable={local_provider?(@current_project)}
                />
              <% _ -> %>
                <.overview_section
                  counters={@counters}
                  stories={@stories}
                  orchestrator_status={@orchestrator_status}
                  project={@current_project}
                  recent_runs={@recent_runs}
                  stories_view={@stories_view}
                />
            <% end %>

            <%= if @artifact_preview do %>
              <.artifact_preview_modal preview={@artifact_preview} />
            <% end %>
          </div>
        </main>

        <.story_editor_modal
          mode={@story_form_mode}
          values={@story_form_values}
          error={@story_form_error}
        />

        <.action_confirmation_modal confirmation={@action_confirmation} />

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

              <%= if story_testing_notes(@selected_story) != "" do %>
                <div class="mb-4">
                  <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                    Testing Notes (Tester Only)
                  </h3>
                  <div class="prose prose-sm max-w-none text-base-content/70">
                    {raw(markdown_to_html(story_testing_notes(@selected_story)))}
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
  attr :stories_view, :string, default: @default_stories_view

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
                  navigate={run_detail_path(@project.slug, run.story_id, run.attempt, @stories_view)}
                  class="flex items-center gap-3 p-3 bg-base-100 rounded-lg hover:bg-base-300 transition-colors"
                >
                  <.run_status_badge status={run.status} />
                  <span class="font-mono text-xs text-base-content/60 shrink-0">{run.story_id}</span>
                  <span class="text-sm truncate flex-1">{run.story_title}</span>
                  <%= if show_recent_activity_phase_label?(run) do %>
                    <span class="text-xs text-base-content/60 shrink-0">{run.phase_label}</span>
                  <% end %>
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
  attr :collapsed_story_groups, :any, default: MapSet.new()
  attr :run_attempts, :list, default: []

  defp stories_section(assigns) do
    groups = build_story_groups(assigns.stories)

    assigns =
      assigns
      |> assign(:groups, groups)
      |> assign(:latest_run_by_story, latest_run_by_story_id(assigns.run_attempts))
      |> assign(:editable, local_provider?(assigns.project))
      |> assign(:stories_view, normalize_stories_view(assigns.stories_view))
      |> assign(
        :collapsed_story_groups,
        normalize_collapsed_story_groups(assigns.collapsed_story_groups)
      )

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

      <%= if @editable && @stories_view == "kanban" do %>
        <p
          id="stories-dnd-feedback"
          data-dnd-feedback
          role="status"
          aria-live="polite"
          class="min-h-[1.25rem] text-sm text-base-content/60"
        >
        </p>
        <span data-dnd-live-region class="sr-only" aria-live="assertive"></span>
      <% end %>

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
          <.stories_kanban_view
            groups={@groups}
            project={@project}
            editable={@editable}
            latest_run_by_story={@latest_run_by_story}
          />
        <% else %>
          <.stories_list_view
            groups={@groups}
            project={@project}
            editable={@editable}
            collapsed_story_groups={@collapsed_story_groups}
            latest_run_by_story={@latest_run_by_story}
          />
        <% end %>
      <% end %>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".StoriesViewPreference">
      export default {
        mounted() {
          this.restoringPreference = false
          this.pendingPreferenceView = null
          this.restoreViewPreference()
        },

        updated() {
          const current = this.normalizeView(this.el.dataset.currentView)

          if (this.restoringPreference) {
            if (current && current === this.pendingPreferenceView) {
              this.restoringPreference = false
              this.pendingPreferenceView = null
              this.persistCurrentView()
            }

            return
          }

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
              this.restoringPreference = true
              this.pendingPreferenceView = stored
              this.pushEvent("set_stories_view", {view: stored})
              return
            }

            this.restoringPreference = false
            this.pendingPreferenceView = null
            this.persistCurrentView()
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
  attr :collapsed_story_groups, :any, default: MapSet.new()
  attr :latest_run_by_story, :map, default: %{}

  defp stories_list_view(assigns) do
    assigns =
      assigns
      |> assign(:status_columns, @story_status_columns)
      |> assign(
        :collapsed_story_groups,
        normalize_collapsed_story_groups(assigns.collapsed_story_groups)
      )

    ~H"""
    <div id="stories-list-view" class="space-y-4">
      <%= for {status, label} <- @status_columns do %>
        <% stories = Map.get(@groups, status, []) %>
        <%= if stories != [] do %>
          <% collapsed = MapSet.member?(@collapsed_story_groups, status) %>
          <section
            id={"stories-list-group-#{status}"}
            class={[
              "rounded-xl border border-base-300 bg-base-200/60",
              status == "draft" && "opacity-80"
            ]}
          >
            <button
              type="button"
              id={"stories-list-group-toggle-#{status}"}
              phx-click="toggle_story_group"
              phx-value-status={status}
              aria-expanded={to_string(!collapsed)}
              class="flex w-full items-center justify-between gap-3 px-4 py-3 text-left"
            >
              <span class="flex items-center gap-2 text-sm font-semibold sm:text-base">
                <.status_badge status={status} />
                {label}
                <span class="badge badge-sm badge-ghost">{length(stories)}</span>
              </span>
              <.icon
                name={if(collapsed, do: "hero-chevron-right", else: "hero-chevron-down")}
                class="size-4 text-base-content/60"
              />
            </button>

            <%= unless collapsed do %>
              <div id={"stories-list-group-content-#{status}"} class="space-y-2 px-4 pb-4">
                <%= for story <- stories do %>
                  <.story_card
                    story={story}
                    project={@project}
                    editable={@editable}
                    stories_view="list"
                    latest_run={Map.get(@latest_run_by_story, story["id"])}
                  />
                <% end %>
              </div>
            <% end %>
          </section>
        <% end %>
      <% end %>
    </div>
    """
  end

  attr :groups, :map, required: true
  attr :project, Project, required: true
  attr :editable, :boolean, default: false
  attr :latest_run_by_story, :map, default: %{}

  defp stories_kanban_view(assigns) do
    assigns = assign(assigns, :status_columns, @story_status_columns)

    ~H"""
    <div
      id="stories-kanban-view"
      class="-mx-2 overflow-x-auto px-2 pb-2"
      phx-hook={@editable && ".KanbanBoardDnD"}
    >
      <div class="flex min-w-full items-start gap-3">
        <%= for {status, label} <- @status_columns do %>
          <.stories_kanban_column
            status={status}
            label={label}
            stories={Map.get(@groups, status, [])}
            project={@project}
            editable={@editable}
            latest_run_by_story={@latest_run_by_story}
          />
        <% end %>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".KanbanBoardDnD">
      const DRAGGING_CARD_CLASSES = ["opacity-70"]
      const TARGET_ALLOWED_CLASSES = ["border-success", "bg-base-100"]
      const TARGET_DISABLED_CLASSES = ["opacity-70"]
      const TARGET_HOVER_ALLOWED_CLASSES = ["border-primary", "shadow-lg"]
      const TARGET_HOVER_DENIED_CLASSES = ["border-error"]

      export default {
        mounted() {
          this.activeDrag = null
          this.hoverTarget = null
          this.touchDrag = null
          this.feedbackTimeout = null
          this.feedbackEl = document.getElementById("stories-dnd-feedback")
          this.liveRegionEl = null

          const storiesSection = this.el.closest("#stories-section")
          if (storiesSection) {
            this.liveRegionEl = storiesSection.querySelector("[data-dnd-live-region]")
          }

          this.onDragStart = (event) => this.handleDragStart(event)
          this.onDragOver = (event) => this.handleDragOver(event)
          this.onDrop = (event) => this.handleDrop(event)
          this.onDragLeave = (event) => this.handleDragLeave(event)
          this.onDragEnd = (_event) => this.endDragSession()
          this.onPointerDown = (event) => this.handlePointerDown(event)

          this.el.addEventListener("dragstart", this.onDragStart)
          this.el.addEventListener("dragover", this.onDragOver)
          this.el.addEventListener("drop", this.onDrop)
          this.el.addEventListener("dragleave", this.onDragLeave)
          this.el.addEventListener("dragend", this.onDragEnd)
          this.el.addEventListener("pointerdown", this.onPointerDown)
        },

        updated() {
          if (this.activeDrag && !this.findStoryCard(this.activeDrag.storyId)) {
            this.endDragSession()
          }
        },

        destroyed() {
          clearTimeout(this.feedbackTimeout)
          this.removeTouchListeners()
          this.removeTouchGhost()

          this.el.removeEventListener("dragstart", this.onDragStart)
          this.el.removeEventListener("dragover", this.onDragOver)
          this.el.removeEventListener("drop", this.onDrop)
          this.el.removeEventListener("dragleave", this.onDragLeave)
          this.el.removeEventListener("dragend", this.onDragEnd)
          this.el.removeEventListener("pointerdown", this.onPointerDown)
        },

        storyCards() {
          return Array.from(this.el.querySelectorAll("[data-story-card='true']"))
        },

        dropTargets() {
          return Array.from(this.el.querySelectorAll("[data-story-drop-target='true']"))
        },

        findStoryCard(storyId) {
          return this.el.querySelector(`[data-story-card='true'][data-story-id='${storyId}']`)
        },

        normalizeStatus(value) {
          if (typeof value !== "string") return ""
          return value.trim().toLowerCase().replace(/[\s-]+/g, "_")
        },

        statusLabel(status) {
          return this.normalizeStatus(status)
            .split("_")
            .filter((part) => part !== "")
            .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
            .join(" ")
        },

        parseTargets(rawTargets) {
          if (typeof rawTargets !== "string" || rawTargets.trim() === "") return []

          return rawTargets
            .split(",")
            .map((target) => this.normalizeStatus(target))
            .filter((target) => target !== "")
        },

        addClasses(el, classes) {
          classes.forEach((className) => el.classList.add(className))
        },

        removeClasses(el, classes) {
          classes.forEach((className) => el.classList.remove(className))
        },

        startDragSession(card) {
          const storyId = card.dataset.storyId
          if (!storyId) return false

          const fromStatus = this.normalizeStatus(card.dataset.storyStatus)
          const allowedTargets = this.parseTargets(card.dataset.storyManualTargets)

          if (allowedTargets.length === 0) {
            this.showFeedback(`No manual transitions available for ${storyId}.`, "error")
            return false
          }

          this.activeDrag = {storyId, fromStatus, allowedTargets, card}
          this.addClasses(card, DRAGGING_CARD_CLASSES)
          card.setAttribute("aria-grabbed", "true")
          this.applyDropTargetState()
          return true
        },

        endDragSession() {
          if (this.activeDrag && this.activeDrag.card) {
            this.removeClasses(this.activeDrag.card, DRAGGING_CARD_CLASSES)
            this.activeDrag.card.setAttribute("aria-grabbed", "false")
          }

          this.activeDrag = null
          this.clearHoverTarget()
          this.resetDropTargetState()
        },

        applyDropTargetState() {
          if (!this.activeDrag) return

          this.dropTargets().forEach((target) => {
            const status = this.normalizeStatus(target.dataset.storyStatus)
            const allowed = this.activeDrag.allowedTargets.includes(status)
            target.dataset.dropAllowed = allowed ? "true" : "false"
            this.removeClasses(target, TARGET_ALLOWED_CLASSES)
            this.removeClasses(target, TARGET_DISABLED_CLASSES)
            this.addClasses(target, allowed ? TARGET_ALLOWED_CLASSES : TARGET_DISABLED_CLASSES)
          })
        },

        resetDropTargetState() {
          this.dropTargets().forEach((target) => {
            delete target.dataset.dropAllowed
            this.removeClasses(target, TARGET_ALLOWED_CLASSES)
            this.removeClasses(target, TARGET_DISABLED_CLASSES)
            this.removeClasses(target, TARGET_HOVER_ALLOWED_CLASSES)
            this.removeClasses(target, TARGET_HOVER_DENIED_CLASSES)
          })
        },

        allowedStatusList() {
          if (!this.activeDrag) return ""
          return this.activeDrag.allowedTargets.map((status) => this.statusLabel(status)).join(", ")
        },

        setHoverTarget(target) {
          if (this.hoverTarget === target) return
          this.clearHoverTarget()

          if (!target || !this.activeDrag) return

          const status = this.normalizeStatus(target.dataset.storyStatus)
          const classes = this.activeDrag.allowedTargets.includes(status)
            ? TARGET_HOVER_ALLOWED_CLASSES
            : TARGET_HOVER_DENIED_CLASSES

          this.addClasses(target, classes)
          this.hoverTarget = target
        },

        clearHoverTarget() {
          if (!this.hoverTarget) return

          this.removeClasses(this.hoverTarget, TARGET_HOVER_ALLOWED_CLASSES)
          this.removeClasses(this.hoverTarget, TARGET_HOVER_DENIED_CLASSES)
          this.hoverTarget = null
        },

        commitDrop(target) {
          if (!this.activeDrag) return

          const targetStatus = this.normalizeStatus(target.dataset.storyStatus)
          const {storyId, fromStatus, allowedTargets} = this.activeDrag

          if (!targetStatus) {
            this.showFeedback("Drop target is missing a status.", "error")
            return
          }

          if (targetStatus === fromStatus) {
            this.showFeedback(`${storyId} is already ${this.statusLabel(targetStatus)}.`, "error")
            return
          }

          if (!allowedTargets.includes(targetStatus)) {
            this.showFeedback(
              `Cannot move ${storyId} to ${this.statusLabel(targetStatus)}. Allowed: ${this.allowedStatusList()}.`,
              "error"
            )
            return
          }

          this.pushEvent("move_story_card", {
            id: storyId,
            from_status: fromStatus,
            to_status: targetStatus
          })

          this.showFeedback(`Moved ${storyId} to ${this.statusLabel(targetStatus)}.`, "success")
        },

        showFeedback(message, level) {
          if (this.feedbackEl) {
            this.feedbackEl.textContent = message
            this.feedbackEl.classList.remove("text-error", "text-success", "text-base-content/60")
            this.feedbackEl.classList.add(level === "success" ? "text-success" : "text-error")
          }

          if (this.liveRegionEl) {
            this.liveRegionEl.textContent = message
          }

          clearTimeout(this.feedbackTimeout)
          this.feedbackTimeout = window.setTimeout(() => {
            if (this.feedbackEl) {
              this.feedbackEl.textContent = ""
              this.feedbackEl.classList.remove("text-error", "text-success")
              this.feedbackEl.classList.add("text-base-content/60")
            }
          }, 3500)
        },

        handleDragStart(event) {
          const card = event.target.closest("[data-story-card='true']")
          if (!card || !this.startDragSession(card)) {
            event.preventDefault()
            return
          }

          if (event.dataTransfer) {
            event.dataTransfer.effectAllowed = "move"
            event.dataTransfer.setData("text/plain", this.activeDrag.storyId)
          }
        },

        handleDragOver(event) {
          if (!this.activeDrag) return
          const target = event.target.closest("[data-story-drop-target='true']")
          if (!target) return

          event.preventDefault()
          this.setHoverTarget(target)

          if (event.dataTransfer) {
            const targetStatus = this.normalizeStatus(target.dataset.storyStatus)
            event.dataTransfer.dropEffect = this.activeDrag.allowedTargets.includes(targetStatus)
              ? "move"
              : "none"
          }
        },

        handleDrop(event) {
          if (!this.activeDrag) return
          const target = event.target.closest("[data-story-drop-target='true']")
          if (!target) return

          event.preventDefault()
          this.commitDrop(target)
          this.endDragSession()
        },

        handleDragLeave(event) {
          if (!this.hoverTarget) return
          const target = event.target.closest("[data-story-drop-target='true']")
          if (!target || target !== this.hoverTarget) return

          const related = event.relatedTarget
          if (!related || !target.contains(related)) {
            this.clearHoverTarget()
          }
        },

        handlePointerDown(event) {
          const handle = event.target.closest("[data-story-touch-handle='true']")
          if (!handle) return
          if (event.pointerType === "mouse") return

          const card = handle.closest("[data-story-card='true']")
          if (!card) return

          event.preventDefault()
          if (!this.startDragSession(card)) return

          this.touchDrag = {
            pointerId: event.pointerId,
            handle,
            ghost: null,
            offsetX: 18,
            offsetY: 18
          }

          if (typeof handle.setPointerCapture === "function") {
            try {
              handle.setPointerCapture(event.pointerId)
            } catch (_error) {
              // Some devices disallow pointer capture; drag still works without it.
            }
          }

          this.createTouchGhost(card)
          this.addTouchListeners()
          this.updateTouchGhostPosition(event.clientX, event.clientY)
          this.updateHoverTargetFromPoint(event.clientX, event.clientY)
        },

        handlePointerMove(event) {
          if (!this.touchDrag || event.pointerId !== this.touchDrag.pointerId) return

          event.preventDefault()
          this.updateTouchGhostPosition(event.clientX, event.clientY)
          this.autoScrollKanban(event.clientX)
          this.updateHoverTargetFromPoint(event.clientX, event.clientY)
        },

        handlePointerUp(event) {
          if (!this.touchDrag || event.pointerId !== this.touchDrag.pointerId) return

          event.preventDefault()
          const target = this.dropTargetFromPoint(event.clientX, event.clientY)

          if (target) {
            this.commitDrop(target)
          } else if (this.activeDrag) {
            this.showFeedback("Drop the story on a status column.", "error")
          }

          this.endTouchDrag()
        },

        handlePointerCancel(event) {
          if (!this.touchDrag || event.pointerId !== this.touchDrag.pointerId) return
          this.endTouchDrag()
        },

        addTouchListeners() {
          this.onPointerMove = (event) => this.handlePointerMove(event)
          this.onPointerUp = (event) => this.handlePointerUp(event)
          this.onPointerCancel = (event) => this.handlePointerCancel(event)

          window.addEventListener("pointermove", this.onPointerMove, {passive: false})
          window.addEventListener("pointerup", this.onPointerUp, {passive: false})
          window.addEventListener("pointercancel", this.onPointerCancel, {passive: false})
        },

        removeTouchListeners() {
          if (this.onPointerMove) {
            window.removeEventListener("pointermove", this.onPointerMove)
            this.onPointerMove = null
          }

          if (this.onPointerUp) {
            window.removeEventListener("pointerup", this.onPointerUp)
            this.onPointerUp = null
          }

          if (this.onPointerCancel) {
            window.removeEventListener("pointercancel", this.onPointerCancel)
            this.onPointerCancel = null
          }
        },

        createTouchGhost(card) {
          const rect = card.getBoundingClientRect()
          const ghost = card.cloneNode(true)

          ghost.removeAttribute("id")
          ghost.querySelectorAll("[id]").forEach((node) => node.removeAttribute("id"))
          ghost.style.position = "fixed"
          ghost.style.top = "0"
          ghost.style.left = "0"
          ghost.style.width = `${rect.width}px`
          ghost.style.pointerEvents = "none"
          ghost.style.opacity = "0.92"
          ghost.style.zIndex = "90"
          ghost.style.transform = "translate(-9999px, -9999px)"
          this.addClasses(ghost, ["shadow-xl"])
          document.body.appendChild(ghost)

          if (this.touchDrag) {
            this.touchDrag.ghost = ghost
          }
        },

        removeTouchGhost() {
          if (!this.touchDrag || !this.touchDrag.ghost) return
          this.touchDrag.ghost.remove()
          this.touchDrag.ghost = null
        },

        updateTouchGhostPosition(clientX, clientY) {
          if (!this.touchDrag || !this.touchDrag.ghost) return

          const left = clientX + this.touchDrag.offsetX
          const top = clientY + this.touchDrag.offsetY
          this.touchDrag.ghost.style.transform = `translate(${left}px, ${top}px)`
        },

        dropTargetFromPoint(clientX, clientY) {
          const target = document.elementFromPoint(clientX, clientY)
          if (!target) return null
          return target.closest("[data-story-drop-target='true']")
        },

        updateHoverTargetFromPoint(clientX, clientY) {
          this.setHoverTarget(this.dropTargetFromPoint(clientX, clientY))
        },

        autoScrollKanban(clientX) {
          const rect = this.el.getBoundingClientRect()
          const edge = 56

          if (clientX < rect.left + edge) {
            this.el.scrollLeft -= 18
          } else if (clientX > rect.right - edge) {
            this.el.scrollLeft += 18
          }
        },

        endTouchDrag() {
          if (this.touchDrag && this.touchDrag.handle) {
            const {handle, pointerId} = this.touchDrag

            if (typeof handle.releasePointerCapture === "function") {
              try {
                handle.releasePointerCapture(pointerId)
              } catch (_error) {
                // Ignore if pointer capture is already released.
              }
            }
          }

          this.removeTouchListeners()
          this.removeTouchGhost()
          this.touchDrag = null
          this.endDragSession()
        }
      }
    </script>
    """
  end

  attr :status, :string, required: true
  attr :label, :string, required: true
  attr :stories, :list, default: []
  attr :project, Project, required: true
  attr :editable, :boolean, default: false
  attr :latest_run_by_story, :map, default: %{}

  defp stories_kanban_column(assigns) do
    assigns =
      assign(assigns, :column_classes, [
        "min-w-[18rem] basis-[18rem] grow shrink-0 overflow-hidden rounded-xl border border-base-300 bg-base-200/60",
        assigns.status == "draft" && "opacity-80"
      ])

    ~H"""
    <section
      id={"stories-column-#{@status}"}
      class={[@column_classes, @editable && "transition-colors duration-150"]}
      data-story-drop-target={@editable && "true"}
      data-story-status={@status}
      aria-disabled={if(@editable, do: "false", else: "true")}
    >
      <header class="flex items-center justify-between gap-2 border-b border-base-300 px-3 py-2">
        <div class="flex min-w-0 items-center gap-2">
          <.status_badge status={@status} />
          <span class="truncate text-sm font-semibold">{@label}</span>
        </div>
        <span class="badge badge-sm badge-ghost">{length(@stories)}</span>
      </header>

      <div class="space-y-2 p-3">
        <%= if @stories == [] do %>
          <p class="px-1 py-4 text-xs text-base-content/40">No stories</p>
        <% else %>
          <%= for story <- @stories do %>
            <.story_card
              story={story}
              project={@project}
              editable={@editable}
              stories_view="kanban"
              latest_run={Map.get(@latest_run_by_story, story["id"])}
            />
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  attr :story, :map, required: true
  attr :project, Project, required: true
  attr :editable, :boolean, default: false
  attr :stories_view, :string, default: @default_stories_view
  attr :latest_run, :map, default: nil

  defp story_card(assigns) do
    status = normalize_status(assigns.story["status"])
    status_targets = manual_status_targets(assigns.story["status"])
    show_reset = show_reset_action?(status)
    can_drag = assigns.editable && status_targets != []

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:status_targets, status_targets)
      |> assign(:show_reset, show_reset)
      |> assign(:reset_label, reset_action_label(status))
      |> assign(:can_drag, can_drag)
      |> assign(:status_targets_csv, Enum.join(status_targets, ","))

    ~H"""
    <div
      id={"story-card-#{@story["id"]}"}
      class={[
        "card border border-base-300 bg-base-200 shadow-sm",
        @status == "draft" && "border-dashed",
        @can_drag && "cursor-grab active:cursor-grabbing"
      ]}
      data-story-card="true"
      data-story-id={@story["id"]}
      data-story-status={@status}
      data-story-manual-targets={@status_targets_csv}
      draggable={@can_drag}
      aria-grabbed="false"
    >
      <div class="card-body gap-3 p-4">
        <div class="flex items-start justify-between gap-3">
          <div class="min-w-0 flex-1 space-y-2">
            <div class="flex items-center justify-between gap-2">
              <.link
                navigate={story_detail_path(@project.slug, @story["id"], @stories_view)}
                class="font-mono text-sm font-semibold text-primary hover:underline"
              >
                {@story["id"]}
              </.link>
              <.status_badge status={@status} />
            </div>

            <.link
              navigate={story_detail_path(@project.slug, @story["id"], @stories_view)}
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

            <%= if @latest_run do %>
              <p class="text-xs text-base-content/60">
                Last run: {Map.get(@latest_run, :phase_label, "Unknown phase")} · {run_number(
                  Map.get(@latest_run, :attempt)
                )}
              </p>
            <% end %>
          </div>

          <%= if @editable do %>
            <div class="flex shrink-0 items-start gap-1">
              <button
                type="button"
                class={[
                  "btn btn-ghost btn-xs touch-manipulation",
                  @can_drag && "cursor-grab active:cursor-grabbing",
                  !@can_drag && "btn-disabled pointer-events-none opacity-60"
                ]}
                data-story-touch-handle={@can_drag && "true"}
                style={@can_drag && "touch-action: none;"}
                title={
                  if @can_drag do
                    "Drag to move story"
                  else
                    "No manual transitions available"
                  end
                }
                aria-label={"Drag #{@story["id"]} to another status"}
                disabled={!@can_drag}
              >
                <.icon name="hero-bars-3" class="size-4" />
              </button>

              <.story_actions_menu
                story={@story}
                status_targets={@status_targets}
                show_reset={@show_reset}
                reset_label={@reset_label}
              />
            </div>
          <% end %>
        </div>

        <%= if @story["lastError"] do %>
          <p class="line-clamp-2 break-words text-sm text-error">{@story["lastError"]}</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :story, :map, required: true
  attr :status_targets, :list, default: []
  attr :show_reset, :boolean, default: false
  attr :reset_label, :string, default: "Reset Story"

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
              onclick={confirm_onclick("Delete #{@story["id"]}? This cannot be undone.")}
              class="text-xs text-error"
            >
              Delete Story
            </button>
          </li>
          <%= if @show_reset do %>
            <li>
              <button
                type="button"
                phx-click="reset_story"
                phx-value-id={@story["id"]}
                class="text-xs text-warning"
              >
                {@reset_label}
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

  defp normalize_collapsed_story_groups(%MapSet{} = collapsed_story_groups),
    do: collapsed_story_groups

  defp normalize_collapsed_story_groups(collapsed_story_groups)
       when is_list(collapsed_story_groups) do
    collapsed_story_groups
    |> Enum.map(&normalize_status/1)
    |> MapSet.new()
  end

  defp normalize_collapsed_story_groups(_collapsed_story_groups), do: MapSet.new()

  defp toggle_collapsed_story_group(collapsed_story_groups, status) do
    collapsed_story_groups = normalize_collapsed_story_groups(collapsed_story_groups)

    if MapSet.member?(collapsed_story_groups, status) do
      MapSet.delete(collapsed_story_groups, status)
    else
      MapSet.put(collapsed_story_groups, status)
    end
  end

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
      |> assign(:agent_kind_options, @agent_kind_options)

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

              <div class="rounded-lg border border-base-300 p-3 space-y-3">
                <h4 class="text-sm font-semibold">Execution Overrides</h4>
                <p class="text-xs text-base-content/60">
                  Optional per-story overrides. Leave blank to use workflow defaults.
                </p>

                <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Main Agent Kind</span>
                    </label>
                    <select
                      name="story[execution_agent_kind]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option value="" selected={Map.get(@values, "execution_agent_kind", "") == ""}>
                        Use workflow default
                      </option>
                      <%= for kind <- @agent_kind_options do %>
                        <option
                          value={kind}
                          selected={Map.get(@values, "execution_agent_kind", "") == kind}
                        >
                          {kind}
                        </option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Review Agent Kind</span>
                    </label>
                    <select
                      name="story[execution_review_agent_kind]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option
                        value=""
                        selected={Map.get(@values, "execution_review_agent_kind", "") == ""}
                      >
                        Use workflow default
                      </option>
                      <%= for kind <- @agent_kind_options do %>
                        <option
                          value={kind}
                          selected={Map.get(@values, "execution_review_agent_kind", "") == kind}
                        >
                          {kind}
                        </option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Review Max Cycles</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      name="story[execution_review_max_cycles]"
                      value={Map.get(@values, "execution_review_max_cycles", "")}
                      class="input input-bordered input-sm w-full"
                      placeholder="Use workflow default"
                    />
                  </div>

                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Testing Enabled</span>
                    </label>
                    <select
                      name="story[execution_testing_enabled]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option
                        value=""
                        selected={Map.get(@values, "execution_testing_enabled", "") == ""}
                      >
                        Use workflow default
                      </option>
                      <option
                        value="true"
                        selected={Map.get(@values, "execution_testing_enabled", "") == "true"}
                      >
                        Enabled
                      </option>
                      <option
                        value="false"
                        selected={Map.get(@values, "execution_testing_enabled", "") == "false"}
                      >
                        Disabled
                      </option>
                    </select>
                  </div>

                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Testing Agent Kind</span>
                    </label>
                    <select
                      name="story[execution_testing_agent_kind]"
                      class="select select-bordered select-sm w-full"
                    >
                      <option
                        value=""
                        selected={Map.get(@values, "execution_testing_agent_kind", "") == ""}
                      >
                        Use workflow default
                      </option>
                      <%= for kind <- @agent_kind_options do %>
                        <option
                          value={kind}
                          selected={Map.get(@values, "execution_testing_agent_kind", "") == kind}
                        >
                          {kind}
                        </option>
                      <% end %>
                    </select>
                  </div>

                  <div>
                    <label class="label py-1">
                      <span class="label-text text-sm">Testing Max Cycles</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      name="story[execution_testing_max_cycles]"
                      value={Map.get(@values, "execution_testing_max_cycles", "")}
                      class="input input-bordered input-sm w-full"
                      placeholder="Use workflow default"
                    />
                  </div>
                </div>
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

              <div>
                <label class="label py-1">
                  <span class="label-text text-sm">Testing Notes (Testing Agent Only)</span>
                </label>
                <textarea
                  name="story[testingNotes]"
                  rows="3"
                  class="textarea textarea-bordered w-full text-sm"
                >{Map.get(@values, "testingNotes", "")}</textarea>
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

  attr :confirmation, :map, default: nil

  defp action_confirmation_modal(assigns) do
    confirmation = if is_map(assigns.confirmation), do: assigns.confirmation, else: nil

    assigns =
      assigns
      |> assign(:confirmation, confirmation)
      |> assign(
        :confirm_button_class,
        if(confirmation && confirmation[:event] == "reset_story",
          do: "btn btn-warning btn-sm",
          else: "btn btn-primary btn-sm"
        )
      )

    ~H"""
    <%= if @confirmation do %>
      <div
        class="fixed inset-0 z-[75] flex items-center justify-center p-4"
        role="dialog"
        aria-modal="true"
      >
        <button
          type="button"
          class="absolute inset-0 bg-black/60"
          phx-click="cancel_action_confirmation"
          aria-label="Close confirmation"
        >
        </button>

        <div class="relative z-10 w-full max-w-lg rounded-xl border border-base-300 bg-base-100 p-5 shadow-xl">
          <div class="space-y-2">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Confirm action
            </p>
            <h3 class="text-lg font-semibold">{@confirmation[:title] || "Confirm"}</h3>
            <p class="text-sm text-base-content/80 whitespace-pre-wrap">{@confirmation[:message]}</p>
          </div>

          <div class="mt-5 flex items-center justify-end gap-2">
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_action_confirmation">
              Cancel
            </button>

            <button
              type="button"
              phx-click={@confirmation[:event]}
              phx-value-id={@confirmation[:id]}
              phx-value-story_id={@confirmation[:story_id]}
              phx-value-attempt={@confirmation[:attempt]}
              phx-value-step={@confirmation[:step]}
              phx-value-confirmed="true"
              phx-disable-with="Working..."
              class={@confirm_button_class}
              data-confirm-action={@confirmation[:event]}
            >
              {@confirmation[:confirm_label] || "Confirm"}
            </button>
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
  attr :stories_view, :string, default: @default_stories_view

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
                <th>Phase</th>
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
                  <td class="text-sm text-base-content/70">{run.phase_label}</td>
                  <td class="text-sm text-base-content/70" title={format_time_tooltip(run.started_at)}>
                    {format_relative_time(run.started_at)}
                  </td>
                  <td class="text-sm text-base-content/70" title={format_time_tooltip(run.ended_at)}>
                    {format_relative_time(run.ended_at)}
                  </td>
                  <td>
                    <.link
                      navigate={
                        run_detail_path(@project.slug, run.story_id, run.attempt, @stories_view)
                      }
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
                  <th>Phase</th>
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
                    <td class="text-sm text-base-content/60">Unknown phase</td>
                    <td class="text-sm text-base-content/60">{run_number(story_run.run_attempt)}</td>
                    <td>
                      <.link
                        navigate={
                          run_detail_path(
                            @project.slug,
                            story["id"],
                            story_run.run_attempt,
                            @stories_view
                          )
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

  attr :story_id, :string, required: true
  attr :project, :map, required: true
  attr :preview_session, :map, default: nil

  defp preview_controls_panel(assigns) do
    session = assigns.preview_session
    has_session = is_map(session) and session.status in [:running, :starting]

    assigns =
      assigns
      |> assign(:has_session, has_session)
      |> assign(:session_status, if(has_session, do: session.status, else: nil))
      |> assign(:preview_url, if(has_session, do: session.preview_url, else: nil))
      |> assign(:expires_at, if(has_session, do: session.expires_at, else: nil))
      |> assign(:resolved_ports, if(has_session, do: session.resolved_ports, else: %{}))

    ~H"""
    <div class="rounded-xl border border-primary/30 bg-primary/5 p-4 space-y-3">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-semibold text-primary flex items-center gap-2">
          <.icon name="hero-eye" class="size-4" /> Preview Environment
        </h3>
        <span class="badge badge-sm badge-warning">Pending Merge</span>
      </div>

      <%= if @has_session do %>
        <div class="space-y-2">
          <div class="flex items-center gap-2">
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-success opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-success"></span>
            </span>
            <span class="text-sm font-medium text-success">Preview running</span>
          </div>

          <%= if @preview_url do %>
            <a
              href={@preview_url}
              target="_blank"
              rel="noopener"
              class="btn btn-primary btn-sm gap-2"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" /> Open Preview
            </a>
          <% end %>

          <%= if map_size(@resolved_ports) > 0 do %>
            <div class="text-xs text-base-content/60">
              Ports:
              <%= for {name, port} <- @resolved_ports do %>
                <span class="badge badge-ghost badge-xs mx-0.5">{name}={port}</span>
              <% end %>
            </div>
          <% end %>

          <%= if @expires_at do %>
            <p class="text-xs text-base-content/50">
              Expires: {Calendar.strftime(@expires_at, "%Y-%m-%d %H:%M UTC")}
            </p>
          <% end %>

          <div class="flex gap-2 pt-1">
            <button
              phx-click="stop_preview"
              phx-value-story_id={@story_id}
              class="btn btn-outline btn-warning btn-xs"
            >
              Stop Preview
            </button>
            <button
              phx-click="merge_story"
              phx-value-story_id={@story_id}
              onclick={"return confirm('Merge #{@story_id}? This will stop the preview and merge the branch.')"}
              class="btn btn-success btn-xs"
            >
              Approve & Merge
            </button>
          </div>
        </div>
      <% else %>
        <p class="text-sm text-base-content/70">
          Start a preview to validate changes before merging.
        </p>
        <div class="flex gap-2">
          <button
            phx-click="start_preview"
            phx-value-story_id={@story_id}
            class="btn btn-primary btn-sm gap-2"
          >
            <.icon name="hero-play" class="size-4" /> Start Preview
          </button>
          <button
            phx-click="merge_story"
            phx-value-story_id={@story_id}
            onclick={"return confirm('Merge #{@story_id} without previewing?')"}
            class="btn btn-outline btn-success btn-sm"
          >
            Merge Without Preview
          </button>
        </div>
      <% end %>
    </div>
    """
  end

  attr :prompts, :map, default: %{}
  attr :active_prompt_tab, :string, default: "agent"

  defp prompts_section(assigns) do
    prompt_tabs = [
      {"agent", "Agent"},
      {"review", "Review"},
      {"testing", "Test"}
    ]

    assigns = assign(assigns, :prompt_tabs, prompt_tabs)

    ~H"""
    <div class="space-y-3">
      <div class="flex gap-0 border-b border-base-300">
        <%= for {tab, label} <- @prompt_tabs do %>
          <button
            phx-click="set_prompt_tab"
            phx-value-tab={tab}
            class={[
              "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
              @active_prompt_tab == tab && "border-primary text-primary",
              @active_prompt_tab != tab &&
                "border-transparent text-base-content/60 hover:text-base-content"
            ]}
          >
            {label}
            <%= if Map.has_key?(@prompts, tab) do %>
              <span class="ml-1 badge badge-xs badge-primary"></span>
            <% end %>
          </button>
        <% end %>
      </div>

      <% prompt_text = Map.get(@prompts, @active_prompt_tab) %>
      <%= if prompt_text do %>
        <pre class="font-mono text-xs leading-relaxed bg-base-300 p-4 rounded-lg overflow-auto max-h-[75vh] whitespace-pre-wrap">{prompt_text}</pre>
      <% else %>
        <p class="text-base-content/50 text-sm italic">
          No {@active_prompt_tab} prompt captured for this run.
        </p>
      <% end %>
    </div>
    """
  end

  attr :snapshot, :map, default: nil
  attr :run_settings, :map, default: %{}
  attr :current_workflow_identity, :map, default: %{}
  attr :workflow_fingerprint_status, :atom, default: :unknown

  defp settings_used_section(assigns) do
    story_overrides = Map.get(assigns.run_settings || %{}, "story_overrides", %{})
    assigns = assign(assigns, :story_overrides, story_overrides)

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body gap-4">
        <h3 class="card-title text-lg">Settings used</h3>

        <%= if @snapshot do %>
          <div class="grid gap-3 sm:grid-cols-2">
            <.settings_used_field
              label="Attempt workflow fingerprint"
              value={snapshot_workflow_fingerprint(@snapshot)}
              mono={true}
            />
            <.settings_used_field
              label="Current workflow fingerprint"
              value={current_workflow_fingerprint(@current_workflow_identity)}
              mono={true}
            />
            <.settings_used_field
              label="Workflow version"
              value={snapshot_workflow_version(@snapshot)}
            />
            <.settings_used_field
              label="Workflow path"
              value={snapshot_workflow_path(@snapshot)}
              mono={true}
            />
          </div>

          <%= if @workflow_fingerprint_status == :mismatch do %>
            <div class="alert alert-warning text-sm">
              Current WORKFLOW.md fingerprint differs from this run attempt.
            </div>
          <% end %>

          <%= if @story_overrides != %{} do %>
            <div class="rounded-lg border border-info/30 bg-info/5 p-3">
              <p class="text-xs font-semibold text-info uppercase tracking-wide mb-2">
                Story Overrides Applied
              </p>
              <div class="flex flex-wrap gap-2">
                <%= for {key, value} <- @story_overrides do %>
                  <span class="badge badge-info badge-sm gap-1">
                    {humanize_override_key(key)}: {to_string(value)}
                  </span>
                <% end %>
              </div>
            </div>
          <% end %>

          <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
            <.settings_used_field label="Main agent" value={snapshot_main_agent(@snapshot)} />
            <.settings_used_field label="Review agent" value={snapshot_review_agent(@snapshot)} />
            <.settings_used_field label="Review cycles" value={snapshot_review_cycles(@snapshot)} />
            <.settings_used_field label="Checks" value={snapshot_checks_toggle(@snapshot)} />
            <.settings_used_field label="Review" value={snapshot_review_toggle(@snapshot)} />
            <.settings_used_field label="Testing" value={snapshot_testing_toggle(@snapshot)} />
            <.settings_used_field label="Publish" value={snapshot_publish_toggle(@snapshot)} />
            <.settings_used_field label="Runtime" value={snapshot_runtime_toggle(@snapshot)} />
            <.settings_used_field label="Preview" value={snapshot_preview_toggle(@snapshot)} />
          </div>
        <% else %>
          <p class="text-sm text-base-content/60 italic">Settings snapshot unavailable.</p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp settings_used_field(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-3 min-w-0">
      <p class="text-xs font-semibold text-base-content/55 uppercase tracking-wide">{@label}</p>
      <p class={[
        "mt-1 min-w-0 break-words text-sm",
        @mono && "font-mono text-xs break-all"
      ]}>
        {@value}
      </p>
    </div>
    """
  end

  attr :report, :map, default: nil
  attr :cycles, :list, default: []
  attr :cycle_reports, :list, default: []

  defp review_report_section(assigns) do
    report = if is_map(assigns.report), do: assigns.report, else: nil
    findings = if report, do: Map.get(report, "findings", []), else: []
    verdict = if report, do: Map.get(report, "verdict"), else: nil
    summary = if report, do: Map.get(report, "summary"), else: nil
    raw_json = if report, do: pretty_json(Map.get(report, "raw")), else: nil

    assigns =
      assigns
      |> assign(:report, report)
      |> assign(:findings, if(is_list(findings), do: findings, else: []))
      |> assign(:verdict, verdict)
      |> assign(:summary, summary)
      |> assign(:raw_json, raw_json)
      |> assign(:cycles, normalize_report_cycles(assigns.cycles))
      |> assign(:cycle_reports, normalize_review_cycle_reports(assigns.cycle_reports))

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="card-title text-lg">Review report</h3>

          <%= if @report do %>
            <span class={review_verdict_badge_class(@verdict)}>
              {String.upcase(to_string(@verdict || "unknown"))}
            </span>
          <% end %>
        </div>

        <%= if @report do %>
          <div class="text-xs text-base-content/60">
            {length(@findings)} findings - {length(@cycles)} cycles
          </div>

          <%= if @cycles != [] do %>
            <div class="flex flex-wrap gap-2">
              <%= for cycle <- @cycles do %>
                <% cycle_num = Map.get(cycle, "cycle") %>
                <% cycle_label = if is_integer(cycle_num), do: "Cycle #{cycle_num}", else: "Cycle ?" %>
                <span class={testing_checkpoint_badge_class(Map.get(cycle, "status"))}>
                  {cycle_label}: {String.upcase(to_string(Map.get(cycle, "status") || "unknown"))}
                </span>
              <% end %>
            </div>
          <% end %>

          <%= if is_binary(@summary) and String.trim(@summary) != "" do %>
            <p class="text-sm text-base-content/80 break-words">{@summary}</p>
          <% end %>

          <%= if @findings != [] do %>
            <div class="space-y-2">
              <%= for finding <- @findings do %>
                <% severity = Map.get(finding, "severity") || "minor" %>
                <div class="rounded-lg border border-base-300 bg-base-100 p-3">
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <span class={review_finding_severity_badge_class(severity)}>
                      {String.upcase(to_string(severity))}
                    </span>
                  </div>
                  <p class="mt-2 text-xs text-base-content/80 break-words">
                    {Map.get(finding, "description") || "No description provided."}
                  </p>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @cycle_reports != [] do %>
            <div class="space-y-2">
              <p class="text-xs font-semibold text-base-content/55 uppercase tracking-wide">
                Per-cycle review.json
              </p>
              <%= for cycle_report <- @cycle_reports do %>
                <% cycle_num = Map.get(cycle_report, "cycle") %>
                <% cycle_label = if is_integer(cycle_num), do: "Cycle #{cycle_num}", else: "Cycle ?" %>
                <% cycle_verdict = Map.get(cycle_report, "verdict") || "unknown" %>
                <% cycle_summary = Map.get(cycle_report, "summary") %>
                <% cycle_findings = Map.get(cycle_report, "findings", []) %>
                <% cycle_raw_json = pretty_json(Map.get(cycle_report, "raw")) %>
                <details class="rounded-lg border border-base-300 bg-base-100 p-3">
                  <summary class="cursor-pointer text-sm font-medium">
                    {cycle_label} - {String.upcase(to_string(cycle_verdict))}
                    <%= if is_binary(cycle_summary) and String.trim(cycle_summary) != "" do %>
                      - {cycle_summary}
                    <% end %>
                  </summary>
                  <div class="mt-3 space-y-2">
                    <%= if cycle_findings != [] do %>
                      <div class="text-xs text-base-content/70">
                        {length(cycle_findings)} findings in this cycle
                      </div>
                    <% end %>
                    <%= if is_binary(cycle_raw_json) and String.trim(cycle_raw_json) != "" do %>
                      <pre class="font-mono text-xs whitespace-pre-wrap break-words">{cycle_raw_json}</pre>
                    <% end %>
                  </div>
                </details>
              <% end %>
            </div>
          <% end %>

          <%= if is_binary(@raw_json) and String.trim(@raw_json) != "" do %>
            <details class="rounded-lg border border-base-300 bg-base-100 p-3">
              <summary class="cursor-pointer text-sm font-medium">Raw review.json</summary>
              <pre class="mt-3 font-mono text-xs whitespace-pre-wrap break-words">{@raw_json}</pre>
            </details>
          <% end %>
        <% else %>
          <p class="text-sm text-base-content/60 italic">
            No review report captured for this run.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :report, :map, default: nil
  attr :cycles, :list, default: []
  attr :cycle_reports, :list, default: []
  attr :project_slug, :string, default: nil
  attr :story_id, :string, default: nil
  attr :attempt, :any, default: nil

  defp testing_report_section(assigns) do
    report = if is_map(assigns.report), do: assigns.report, else: nil
    checkpoints = if report, do: Map.get(report, "checkpoints", []), else: []
    artifacts = if report, do: Map.get(report, "artifacts", []), else: []
    verdict = if report, do: Map.get(report, "verdict"), else: nil
    summary = if report, do: Map.get(report, "summary"), else: nil
    raw_json = if report, do: pretty_json(Map.get(report, "raw")), else: nil

    artifacts =
      if is_list(artifacts) do
        Enum.map(artifacts, fn artifact ->
          attach_testing_artifact_preview(
            artifact,
            assigns.project_slug,
            assigns.story_id,
            assigns.attempt
          )
        end)
      else
        []
      end

    cycle_reports =
      assigns.cycle_reports
      |> normalize_testing_cycle_reports()
      |> Enum.map(fn cycle_report ->
        attach_testing_report_artifact_previews(
          cycle_report,
          assigns.project_slug,
          assigns.story_id,
          assigns.attempt
        )
      end)

    assigns =
      assigns
      |> assign(:report, report)
      |> assign(:checkpoints, if(is_list(checkpoints), do: checkpoints, else: []))
      |> assign(:artifacts, artifacts)
      |> assign(:verdict, verdict)
      |> assign(:summary, summary)
      |> assign(:raw_json, raw_json)
      |> assign(:cycles, normalize_report_cycles(assigns.cycles))
      |> assign(:cycle_reports, cycle_reports)

    ~H"""
    <div class="card bg-base-200 border border-base-300">
      <div class="card-body gap-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h3 class="card-title text-lg">Testing report</h3>

          <%= if @report do %>
            <span class={testing_verdict_badge_class(@verdict)}>
              {String.upcase(to_string(@verdict || "unknown"))}
            </span>
          <% end %>
        </div>

        <%= if @report do %>
          <div class="text-xs text-base-content/60">
            {length(@checkpoints)} checkpoints - {length(@artifacts)} artifacts - {length(@cycles)} cycles
          </div>

          <%= if @cycles != [] do %>
            <div class="flex flex-wrap gap-2">
              <%= for cycle <- @cycles do %>
                <% cycle_num = Map.get(cycle, "cycle") %>
                <% cycle_label = if is_integer(cycle_num), do: "Cycle #{cycle_num}", else: "Cycle ?" %>
                <span class={testing_checkpoint_badge_class(Map.get(cycle, "status"))}>
                  {cycle_label}: {String.upcase(to_string(Map.get(cycle, "status") || "unknown"))}
                </span>
              <% end %>
            </div>
          <% end %>

          <%= if is_binary(@summary) and String.trim(@summary) != "" do %>
            <p class="text-sm text-base-content/80 break-words">{@summary}</p>
          <% end %>

          <%= if @checkpoints != [] do %>
            <div class="space-y-2">
              <%= for checkpoint <- @checkpoints do %>
                <div class="rounded-lg border border-base-300 bg-base-100 p-3">
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <p class="text-sm font-medium">{Map.get(checkpoint, "name") || "checkpoint"}</p>
                    <span class={testing_checkpoint_badge_class(Map.get(checkpoint, "status"))}>
                      {String.upcase(to_string(Map.get(checkpoint, "status") || "unknown"))}
                    </span>
                  </div>
                  <%= if details = Map.get(checkpoint, "details") do %>
                    <p class="mt-2 text-xs text-base-content/70 break-words">{details}</p>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>

          <%= if @artifacts != [] do %>
            <.testing_artifacts_table artifacts={@artifacts} />
          <% end %>

          <%= if @cycle_reports != [] do %>
            <div class="space-y-2">
              <p class="text-xs font-semibold text-base-content/55 uppercase tracking-wide">
                Per-cycle testing.json
              </p>
              <%= for cycle_report <- @cycle_reports do %>
                <% cycle_num = Map.get(cycle_report, "cycle") %>
                <% cycle_label = if is_integer(cycle_num), do: "Cycle #{cycle_num}", else: "Cycle ?" %>
                <% cycle_verdict = Map.get(cycle_report, "verdict") || "unknown" %>
                <% cycle_summary = Map.get(cycle_report, "summary") %>
                <% cycle_checkpoints = Map.get(cycle_report, "checkpoints", []) %>
                <% cycle_artifacts = Map.get(cycle_report, "artifacts", []) %>
                <% cycle_raw_json = pretty_json(Map.get(cycle_report, "raw")) %>
                <details class="rounded-lg border border-base-300 bg-base-100 p-3">
                  <summary class="cursor-pointer text-sm font-medium">
                    {cycle_label} - {String.upcase(to_string(cycle_verdict))}
                    <%= if is_binary(cycle_summary) and String.trim(cycle_summary) != "" do %>
                      - {cycle_summary}
                    <% end %>
                  </summary>
                  <div class="mt-3 space-y-3">
                    <%= if cycle_checkpoints != [] do %>
                      <div class="space-y-2">
                        <%= for checkpoint <- cycle_checkpoints do %>
                          <div class="rounded-lg border border-base-300 bg-base-200 p-2">
                            <div class="flex flex-wrap items-center justify-between gap-2">
                              <p class="text-sm font-medium">
                                {Map.get(checkpoint, "name") || "checkpoint"}
                              </p>
                              <span class={
                                testing_checkpoint_badge_class(Map.get(checkpoint, "status"))
                              }>
                                {String.upcase(to_string(Map.get(checkpoint, "status") || "unknown"))}
                              </span>
                            </div>
                            <%= if details = Map.get(checkpoint, "details") do %>
                              <p class="mt-1 text-xs text-base-content/70 break-words">{details}</p>
                            <% end %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                    <%= if cycle_artifacts != [] do %>
                      <.testing_artifacts_table artifacts={cycle_artifacts} />
                    <% end %>
                    <%= if is_binary(cycle_raw_json) and String.trim(cycle_raw_json) != "" do %>
                      <pre class="font-mono text-xs whitespace-pre-wrap break-words">{cycle_raw_json}</pre>
                    <% end %>
                  </div>
                </details>
              <% end %>
            </div>
          <% end %>

          <%= if is_binary(@raw_json) and String.trim(@raw_json) != "" do %>
            <details class="rounded-lg border border-base-300 bg-base-100 p-3">
              <summary class="cursor-pointer text-sm font-medium">Raw testing.json</summary>
              <pre class="mt-3 font-mono text-xs whitespace-pre-wrap break-words">{@raw_json}</pre>
            </details>
          <% end %>
        <% else %>
          <p class="text-sm text-base-content/60 italic">
            No testing report captured for this run.
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  attr :artifacts, :list, default: []

  defp testing_artifacts_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Kind</th>
            <th>Preview</th>
          </tr>
        </thead>
        <tbody>
          <%= for artifact <- @artifacts do %>
            <% kind = Map.get(artifact, "kind") || "artifact" %>
            <% stored_url = Map.get(artifact, "stored_url") %>
            <% storage_error = Map.get(artifact, "storage_error") %>
            <% description = Map.get(artifact, "description") %>
            <% preview_url = Map.get(artifact, "preview_url") %>
            <% preview_type = Map.get(artifact, "preview_type") %>
            <tr>
              <td class="align-top">
                <span class="badge badge-outline text-xs">{kind}</span>
              </td>
              <td class="align-top min-w-[14rem]">
                <%= if preview_type in ["image", "video"] and is_binary(preview_url) do %>
                  <button
                    type="button"
                    phx-click="open_artifact_preview"
                    phx-value-url={preview_url}
                    phx-value-type={preview_type}
                    phx-value-title={description || kind}
                    class="group inline-block text-left"
                  >
                    <%= if preview_type == "image" do %>
                      <img
                        src={preview_url}
                        alt={description || kind}
                        class="max-h-40 rounded-lg border border-base-300 bg-base-100 transition group-hover:border-primary"
                      />
                    <% else %>
                      <div class="relative inline-block">
                        <video
                          muted
                          playsinline
                          preload="metadata"
                          class="max-h-40 rounded-lg border border-base-300 bg-base-100 transition group-hover:border-primary"
                        >
                          <source src={preview_url} />
                        </video>
                        <span class="absolute inset-0 flex items-center justify-center rounded-lg bg-black/20 text-xs font-medium text-white">
                          Click to play
                        </span>
                      </div>
                    <% end %>
                  </button>

                  <%= if is_binary(description) and String.trim(description) != "" do %>
                    <p class="mt-1 text-xs text-base-content/60 break-words">{description}</p>
                  <% else %>
                    <p class="mt-1 text-xs text-base-content/50">Click preview to open</p>
                  <% end %>
                <% else %>
                  <%= if is_binary(stored_url) do %>
                    <a
                      href={stored_url}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="link link-primary text-xs"
                    >
                      Open artifact
                    </a>
                  <% else %>
                    <%= if is_binary(storage_error) and String.trim(storage_error) != "" do %>
                      <span class="text-xs text-error break-words">{storage_error}</span>
                    <% else %>
                      <span class="text-xs text-base-content/50">No inline preview</span>
                    <% end %>
                  <% end %>
                <% end %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :preview, :map, required: true

  defp artifact_preview_modal(assigns) do
    preview = if is_map(assigns.preview), do: assigns.preview, else: %{}
    type = Map.get(preview, "type")
    url = Map.get(preview, "url")
    title = Map.get(preview, "title")

    assigns =
      assigns
      |> assign(:preview_type, type)
      |> assign(:preview_url, url)
      |> assign(
        :preview_title,
        if(is_binary(title) and String.trim(title) != "", do: title, else: nil)
      )

    ~H"""
    <div
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
    >
      <button
        type="button"
        class="absolute inset-0 bg-black/60"
        phx-click="close_artifact_preview"
        aria-label="Close artifact preview"
      >
      </button>

      <div class="relative z-10 max-h-[90vh] w-full max-w-5xl overflow-auto rounded-xl border border-base-300 bg-base-100 p-4 shadow-xl">
        <div class="mb-3 flex items-start justify-between gap-3">
          <div class="min-w-0">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Artifact preview
            </p>
            <%= if @preview_title do %>
              <p class="truncate text-sm text-base-content/80">{@preview_title}</p>
            <% end %>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="close_artifact_preview"
            aria-label="Close preview"
          >
            Close
          </button>
        </div>

        <%= if @preview_type == "image" and is_binary(@preview_url) do %>
          <img
            src={@preview_url}
            alt={@preview_title || "artifact image"}
            class="max-h-[75vh] w-auto rounded-lg border border-base-300 bg-base-200"
          />
        <% else %>
          <%= if @preview_type == "video" and is_binary(@preview_url) do %>
            <video
              controls
              autoplay
              preload="metadata"
              class="max-h-[75vh] w-full rounded-lg border border-base-300 bg-base-200"
            >
              <source src={@preview_url} />
            </video>
          <% else %>
            <p class="text-sm text-base-content/60">Preview unavailable.</p>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # -- Run Steps Section (replaces run_detail for step timeline) --

  attr :run_detail, :map, default: nil
  attr :story_id, :string, default: nil
  attr :attempt, :string, default: nil
  attr :project, Project, required: true
  attr :stories_view, :string, default: @default_stories_view
  attr :run_view_tab, :string, default: "steps"

  defp run_steps_section(assigns) do
    run_status =
      if is_map(assigns.run_detail),
        do: get_in(assigns.run_detail, ["metadata", "status"]) || "unknown",
        else: "unknown"

    run_in_progress = run_status in ["running", "in_progress", "claimed"]

    steps =
      if is_map(assigns.run_detail) do
        events = run_detail_events(assigns.run_detail)
        Kollywood.Orchestrator.RunSteps.from_events(events, run_in_progress: run_in_progress)
      else
        []
      end

    visible_steps =
      Enum.filter(steps, fn s ->
        s.kind not in [
          "run_started",
          "workspace_ready",
          "quality_cycle",
          "quality_retry",
          "quality_passed",
          "run_finished",
          "prompt_captured"
        ]
      end)

    run_error =
      if is_map(assigns.run_detail),
        do: get_in(assigns.run_detail, ["metadata", "error"]),
        else: nil

    retryable_idx = retryable_step_idx(visible_steps, run_status)

    snapshot =
      if is_map(assigns.run_detail),
        do: Map.get(assigns.run_detail, "settings_snapshot"),
        else: nil

    run_settings =
      if is_map(assigns.run_detail),
        do: get_in(assigns.run_detail, ["metadata", "run_settings"]) || %{},
        else: %{}

    current_workflow_identity =
      if is_map(assigns.run_detail),
        do: Map.get(assigns.run_detail, "current_workflow_identity"),
        else: %{}

    assigns =
      assigns
      |> assign(:steps, visible_steps)
      |> assign(:run_status, run_status)
      |> assign(:run_error, run_error)
      |> assign(:retryable_idx, retryable_idx)
      |> assign(:settings_snapshot, snapshot)
      |> assign(:run_settings, run_settings)
      |> assign(:current_workflow_identity, current_workflow_identity)
      |> assign(
        :workflow_fingerprint_status,
        workflow_fingerprint_status(snapshot, current_workflow_identity)
      )

    ~H"""
    <div class="flex flex-col gap-4 h-full">
      <div class="flex flex-wrap items-center justify-between gap-2 sm:gap-3">
        <div class="flex min-w-0 flex-wrap items-center gap-2 sm:gap-3">
          <.link
            navigate={story_runs_tab_path(@project.slug, @story_id, @stories_view)}
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Runs
          </.link>
          <span class="badge badge-outline font-mono text-sm">{@story_id}</span>
          <span class="text-sm text-base-content/60">Run {run_number(@attempt)}</span>
          <.run_status_badge status={@run_status} />
        </div>
      </div>

      <%= if @run_error do %>
        <div class="alert alert-error text-sm gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <p class="break-words min-w-0">{@run_error}</p>
        </div>
      <% end %>

      <div class="flex gap-0 border-b border-base-300">
        <%= for {tab, label, icon} <- [
          {"steps", "Steps", "hero-list-bullet"},
          {"settings", "Settings", "hero-cog-6-tooth"}
        ] do %>
          <button
            phx-click="set_run_view_tab"
            phx-value-tab={tab}
            class={[
              "flex items-center gap-1.5 px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
              @run_view_tab == tab && "border-primary text-primary",
              @run_view_tab != tab &&
                "border-transparent text-base-content/60 hover:text-base-content"
            ]}
          >
            <.icon name={icon} class="size-4" />
            {label}
          </button>
        <% end %>
      </div>

      <%= if @run_view_tab == "steps" do %>
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body p-0">
            <h3 class="card-title text-lg px-5 pt-4 pb-2">Pipeline Steps</h3>
            <%= if @steps == [] do %>
              <p class="text-base-content/60 py-4 px-5">No steps recorded yet.</p>
            <% else %>
              <div class="space-y-1 px-3 pb-3">
                <%= for step <- @steps do %>
                  <div class="flex items-center gap-2">
                    <.link
                      navigate={
                        step_detail_path(@project.slug, @story_id, @attempt, step.idx, @stories_view)
                      }
                      class="flex items-center gap-3 p-3 bg-base-100 rounded-lg hover:bg-base-300 transition-colors flex-1 min-w-0"
                    >
                      <.step_status_icon kind={step.kind} status={step.status} />
                      <span class="text-sm font-medium flex-1 truncate">{step.label}</span>
                      <%= if step.error do %>
                        <span class="text-xs text-error truncate max-w-[200px]">{step.error}</span>
                      <% end %>
                      <span class="text-xs text-base-content/50 shrink-0">
                        {format_step_duration(step.duration_ms)}
                      </span>
                    </.link>
                    <%= if step_retryable?(step, @retryable_idx) do %>
                      <button
                        type="button"
                        phx-click="trigger_run"
                        phx-value-story_id={@story_id}
                        phx-value-attempt={@attempt}
                        phx-value-step={step_retry_name(step)}
                        class="btn btn-ghost btn-xs text-primary shrink-0"
                        title={"Retry from #{step.label}"}
                      >
                        <.icon name="hero-arrow-path" class="size-3.5" />
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% else %>
        <.settings_used_section
          snapshot={@settings_snapshot}
          run_settings={@run_settings}
          current_workflow_identity={@current_workflow_identity}
          workflow_fingerprint_status={@workflow_fingerprint_status}
        />
      <% end %>
    </div>
    """
  end

  # -- Step Detail Section --

  attr :run_detail, :map, default: nil
  attr :story_id, :string, default: nil
  attr :attempt, :string, default: nil
  attr :step_idx, :string, default: nil
  attr :step, :map, default: nil
  attr :project, Project, required: true
  attr :stories_view, :string, default: @default_stories_view
  attr :step_detail_tab, :string, default: "logs"

  defp step_detail_section(assigns) do
    step_log_content = step_log_content(assigns.step, assigns.run_detail)
    step_prompt_content = step_prompt_content(assigns.step, assigns.run_detail)

    run_status =
      if is_map(assigns.run_detail),
        do: get_in(assigns.run_detail, ["metadata", "status"]) || "unknown",
        else: "unknown"

    run_in_progress = run_status in ["running", "in_progress", "claimed"]

    all_steps =
      if is_map(assigns.run_detail) do
        events = run_detail_events(assigns.run_detail)
        Kollywood.Orchestrator.RunSteps.from_events(events, run_in_progress: run_in_progress)
      else
        []
      end

    retryable_idx = retryable_step_idx(all_steps, run_status)

    step = assigns.step
    has_prompt = is_binary(step_prompt_content) and String.trim(step_prompt_content) != ""
    has_logs = step_log_content != nil and step_log_content != ""
    has_reports = step && step.kind in ["review", "testing"]

    step_tabs =
      [if(has_logs, do: {"logs", "Logs"})] ++
        [if(has_prompt, do: {"prompt", "Prompt"})] ++
        [if(has_reports, do: {"reports", "Reports"})]

    step_tabs = Enum.reject(step_tabs, &is_nil/1)

    active_tab =
      cond do
        Enum.any?(step_tabs, fn {id, _} -> id == assigns.step_detail_tab end) ->
          assigns.step_detail_tab

        step_tabs != [] ->
          elem(hd(step_tabs), 0)

        true ->
          "logs"
      end

    step_report =
      if step && step.kind == "review" && is_map(assigns.run_detail),
        do: assigns.run_detail["review_report"],
        else: nil

    step_report =
      if step && step.kind == "testing" && is_map(assigns.run_detail),
        do: assigns.run_detail["testing_report"],
        else: step_report

    assigns =
      assigns
      |> assign(:step_log_content, step_log_content)
      |> assign(:retryable_idx, retryable_idx)
      |> assign(:step_tabs, step_tabs)
      |> assign(:active_tab, active_tab)
      |> assign(:has_logs, has_logs)
      |> assign(:has_prompt, has_prompt)
      |> assign(:step_prompt_content, step_prompt_content)
      |> assign(:has_reports, has_reports)
      |> assign(:step_report, step_report)

    ~H"""
    <div class="flex flex-col gap-4 h-full">
      <div class="flex flex-wrap items-center justify-between gap-2 sm:gap-3">
        <div class="flex min-w-0 flex-wrap items-center gap-2 sm:gap-3">
          <.link
            navigate={run_detail_path(@project.slug, @story_id, @attempt, @stories_view)}
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Steps
          </.link>
          <span class="badge badge-outline font-mono text-sm">{@story_id}</span>
          <span class="text-sm text-base-content/60">Run {run_number(@attempt)}</span>
        </div>
      </div>

      <%= if @step do %>
        <div class="flex items-center gap-3">
          <.step_status_icon kind={@step.kind} status={@step.status} />
          <h2 class="text-lg font-semibold">{@step.label}</h2>
          <span class="text-xs text-base-content/50">{format_step_duration(@step.duration_ms)}</span>
          <%= if @step.started_at && @step.started_at != "" do %>
            <span class="text-xs text-base-content/50">{time_ago(@step.started_at)}</span>
          <% end %>
          <%= if step_retryable?(@step, @retryable_idx) do %>
            <button
              type="button"
              phx-click="trigger_run"
              phx-value-story_id={@story_id}
              phx-value-attempt={@attempt}
              phx-value-step={step_retry_name(@step)}
              class="btn btn-sm btn-primary gap-1"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Retry from here
            </button>
          <% end %>
        </div>

        <%= if @step.error do %>
          <div class="alert alert-error text-sm gap-2">
            <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
            <p class="break-words min-w-0">{@step.error}</p>
          </div>
        <% end %>

        <%!-- Checks detail (always visible for checks steps) --%>
        <%= if @step.kind == "checks" && @step.detail[:checks] do %>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4 space-y-2">
              <h3 class="font-medium text-sm">Check Commands</h3>
              <%= for check <- @step.detail[:checks] do %>
                <div class="flex items-center gap-3 p-2 bg-base-100 rounded-lg">
                  <.step_status_icon kind="check" status={check.status} />
                  <code class="text-xs flex-1 truncate">{check.command}</code>
                  <span class="text-xs text-base-content/50">
                    {format_step_duration(check.duration_ms)}
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Runtime events (always visible for runtime/testing steps) --%>
        <%= if @step.kind in ["testing", "runtime"] do %>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body p-4 space-y-2">
              <h3 class="font-medium text-sm">Runtime Events</h3>
              <%= for event <- @step.events do %>
                <% event_type = Map.get(event, "type") || to_string(Map.get(event, :type, "")) %>
                <%= if String.starts_with?(event_type, "runtime_") do %>
                  <div class="flex items-center gap-3 p-2 bg-base-100 rounded-lg">
                    <.runtime_event_icon type={event_type} />
                    <span class="text-xs font-mono flex-1">{event_type}</span>
                    <%= if event["resolved_ports"] do %>
                      <span class="text-xs text-base-content/50">
                        {inspect(event["resolved_ports"])}
                      </span>
                    <% end %>
                    <%= if event["reason"] do %>
                      <span class="text-xs text-error truncate max-w-[250px]">{event["reason"]}</span>
                    <% end %>
                    <span class="text-xs text-base-content/50">{format_event_time(event)}</span>
                  </div>
                <% end %>
              <% end %>
            </div>
          </div>
        <% end %>

        <%!-- Tabs --%>
        <%= if @step_tabs != [] do %>
          <div class="flex gap-0 border-b border-base-300">
            <%= for {tab, label} <- @step_tabs do %>
              <button
                phx-click="set_step_detail_tab"
                phx-value-tab={tab}
                class={[
                  "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
                  @active_tab == tab && "border-primary text-primary",
                  @active_tab != tab &&
                    "border-transparent text-base-content/60 hover:text-base-content"
                ]}
              >
                {label}
              </button>
            <% end %>
          </div>

          <%!-- Logs tab --%>
          <%= if @active_tab == "logs" && @has_logs do %>
            <pre class="text-xs whitespace-pre-wrap break-words flex-1 min-h-[200px] max-h-[75vh] overflow-y-auto bg-neutral text-neutral-content p-4 rounded-lg font-mono"><.ansi_log content={@step_log_content} /></pre>
          <% end %>

          <%!-- Prompt tab --%>
          <%= if @active_tab == "prompt" && @has_prompt do %>
            <pre class="text-xs whitespace-pre-wrap break-words flex-1 min-h-[200px] max-h-[75vh] overflow-y-auto bg-base-300 p-4 rounded-lg">{@step_prompt_content}</pre>
          <% end %>

          <%!-- Reports tab --%>
          <%= if @active_tab == "reports" && @has_reports do %>
            <%= if @step.kind == "review" do %>
              <.review_report_section
                report={if(@run_detail, do: @run_detail["review_report"])}
                cycles={if(@run_detail, do: @run_detail["review_cycles"])}
                cycle_reports={if(@run_detail, do: @run_detail["review_cycle_reports"])}
              />
            <% end %>
            <%= if @step.kind == "testing" do %>
              <.testing_report_section
                report={if(@run_detail, do: @run_detail["testing_report"])}
                cycles={if(@run_detail, do: @run_detail["testing_cycles"])}
                cycle_reports={if(@run_detail, do: @run_detail["testing_cycle_reports"])}
                project_slug={@project.slug}
                story_id={@story_id}
                attempt={if(@run_detail, do: get_in(@run_detail, ["metadata", "attempt"]))}
              />
            <% end %>
          <% end %>
        <% end %>
      <% else %>
        <div class="alert alert-warning">Step not found.</div>
      <% end %>
    </div>
    """
  end

  # -- Step helpers --

  attr :kind, :string, required: true
  attr :status, :string, required: true

  defp step_status_icon(assigns) do
    {icon, color} = step_icon_and_color(assigns.kind, assigns.status)
    assigns = assigns |> assign(:icon, icon) |> assign(:color, color)

    ~H"""
    <div class={["size-6 shrink-0 flex items-center justify-center rounded-full", @color]}>
      <.icon name={@icon} class="size-3.5" />
    </div>
    """
  end

  defp step_icon_and_color(kind, status) do
    case {kind, status} do
      {_, "passed"} -> {"hero-check-mini", "bg-success/20 text-success"}
      {_, "ok"} -> {"hero-check-mini", "bg-success/20 text-success"}
      {_, "failed"} -> {"hero-x-mark-mini", "bg-error/20 text-error"}
      {_, "error"} -> {"hero-exclamation-triangle-mini", "bg-error/20 text-error"}
      {_, "running"} -> {"hero-arrow-path-mini", "bg-warning/20 text-warning"}
      {_, "interrupted"} -> {"hero-pause-mini", "bg-base-content/20 text-base-content/60"}
      {_, "skipped"} -> {"hero-minus-mini", "bg-base-content/20 text-base-content/60"}
      {"agent_turn", _} -> {"hero-cpu-chip-mini", "bg-primary/20 text-primary"}
      {"checks", _} -> {"hero-clipboard-document-check-mini", "bg-info/20 text-info"}
      {"review", _} -> {"hero-eye-mini", "bg-secondary/20 text-secondary"}
      {"testing", _} -> {"hero-beaker-mini", "bg-accent/20 text-accent"}
      {"runtime", _} -> {"hero-server-mini", "bg-base-content/20 text-base-content/60"}
      {"publish", _} -> {"hero-arrow-up-tray-mini", "bg-primary/20 text-primary"}
      {"pending_merge", _} -> {"hero-clock-mini", "bg-warning/20 text-warning"}
      {"preview", _} -> {"hero-eye-mini", "bg-info/20 text-info"}
      _ -> {"hero-ellipsis-horizontal-mini", "bg-base-content/20 text-base-content/60"}
    end
  end

  attr :type, :string, required: true

  defp runtime_event_icon(assigns) do
    {icon, color} =
      case assigns.type do
        "runtime_starting" -> {"hero-play-mini", "text-info"}
        "runtime_started" -> {"hero-check-mini", "text-success"}
        "runtime_healthcheck_started" -> {"hero-heart-mini", "text-info"}
        "runtime_healthcheck_passed" -> {"hero-heart-mini", "text-success"}
        "runtime_healthcheck_failed" -> {"hero-heart-mini", "text-error"}
        "runtime_start_failed" -> {"hero-x-mark-mini", "text-error"}
        "runtime_stopping" -> {"hero-stop-mini", "text-warning"}
        "runtime_stopped" -> {"hero-stop-mini", "text-base-content/60"}
        _ -> {"hero-ellipsis-horizontal-mini", "text-base-content/60"}
      end

    assigns = assigns |> assign(:icon, icon) |> assign(:color, color)

    ~H"""
    <.icon name={@icon} class={["size-4 shrink-0", @color]} />
    """
  end

  defp format_step_duration(nil), do: "-"
  defp format_step_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_step_duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  defp format_step_duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m #{seconds}s"
  end

  defp format_event_time(event) do
    ts = Map.get(event, "timestamp") || Map.get(event, :timestamp)
    if is_binary(ts), do: String.slice(ts, 11, 8), else: ""
  end

  defp step_detail_path(project_slug, story_id, attempt, step_idx, stories_view) do
    base = "/projects/#{project_slug}/runs/#{story_id}/#{attempt}/step/#{step_idx}"
    if stories_view, do: base <> "?view=#{stories_view}", else: base
  end

  @retryable_step_kinds ~w(checks review testing publish runtime)
  @step_kind_to_retry %{
    "checks" => "checks",
    "review" => "review",
    "testing" => "testing",
    "publish" => "publish",
    "runtime" => "testing"
  }

  defp retryable_step_idx(steps, run_status) when is_list(steps) do
    if to_string(run_status) not in ["failed", "error"],
      do: nil,
      else: do_retryable_step_idx(steps)
  end

  defp do_retryable_step_idx(steps) do
    steps
    |> Enum.reverse()
    |> Enum.find(fn s ->
      s.status in ["failed", "error"] and s.kind in @retryable_step_kinds
    end)
    |> case do
      nil ->
        nil

      step ->
        effective_kind = Map.get(@step_kind_to_retry, step.kind, step.kind)

        later_success =
          Enum.any?(steps, fn s ->
            s_kind = Map.get(@step_kind_to_retry, s.kind, s.kind)

            s.idx > step.idx and s_kind == effective_kind and
              retry_step_completed_successfully?(s)
          end)

        if later_success, do: nil, else: step.idx
    end
  end

  defp step_retryable?(step, retryable_idx) do
    retryable_idx != nil and step.idx == retryable_idx
  end

  defp step_retry_name(step) do
    Map.get(@step_kind_to_retry, step.kind, "full_rerun")
  end

  defp retry_step_completed_successfully?(%{kind: "runtime"} = step) do
    step.status in ["ok", "passed"] and not runtime_stop_only_step?(step)
  end

  defp retry_step_completed_successfully?(step), do: step.status in ["ok", "passed"]

  defp runtime_stop_only_step?(%{events: events}) when is_list(events) do
    event_types = Enum.map(events, &runtime_step_event_type/1)

    Enum.any?(event_types, &(&1 == "runtime_stopping")) and
      Enum.any?(event_types, &(&1 == "runtime_stopped")) and
      not Enum.any?(event_types, &(&1 in ["runtime_starting", "runtime_healthcheck_started"]))
  end

  defp runtime_stop_only_step?(_step), do: false

  defp runtime_step_event_type(event) when is_map(event) do
    case Map.get(event, "type") || Map.get(event, :type) do
      value when is_atom(value) -> Atom.to_string(value)
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp runtime_step_event_type(_event), do: ""

  defp step_log_content(nil, _run_detail), do: nil

  defp step_log_content(step, run_detail) when is_map(step) and is_map(run_detail) do
    files = run_detail["files"]
    if is_nil(files), do: nil, else: step_log_for_kind(step.kind, files)
  end

  defp step_log_content(_step, _run_detail), do: nil

  defp step_prompt_content(nil, _run_detail), do: nil

  defp step_prompt_content(step, run_detail) when is_map(step) do
    case Map.get(step, :prompt) do
      value when is_binary(value) ->
        if String.trim(value) == "" do
          fallback_step_prompt(run_detail, Map.get(step, :kind))
        else
          value
        end

      _other ->
        fallback_step_prompt(run_detail, Map.get(step, :kind))
    end
  end

  defp step_prompt_content(_step, _run_detail), do: nil

  defp fallback_step_prompt(run_detail, kind) when is_map(run_detail) do
    phase =
      case kind do
        "agent_turn" -> "agent"
        "review" -> "review"
        "testing" -> "testing"
        _other -> nil
      end

    if is_binary(phase) do
      run_detail
      |> Map.get("prompts", %{})
      |> Map.get(phase)
      |> case do
        value when is_binary(value) -> if(String.trim(value) == "", do: nil, else: value)
        _other -> nil
      end
    else
      nil
    end
  end

  defp fallback_step_prompt(_run_detail, _kind), do: nil

  defp step_log_for_kind("agent_turn", files) do
    read_file_safe(files[:agent_stdout]) || read_file_safe(files[:agent])
  end

  defp step_log_for_kind("checks", files), do: read_file_safe(files[:checks])

  defp step_log_for_kind("review", files),
    do: read_file_safe(files[:reviewer_stdout]) || read_file_safe(files[:reviewer])

  defp step_log_for_kind("testing", files) do
    (read_file_safe(files[:tester_stdout]) || read_file_safe(files[:tester]) || "") <>
      "\n" <> (read_file_safe(files[:runtime]) || "")
  end

  defp step_log_for_kind("runtime", files), do: read_file_safe(files[:runtime])
  defp step_log_for_kind("publish", files), do: read_file_safe(files[:worker])
  defp step_log_for_kind(_kind, _files), do: nil

  defp read_file_safe(nil), do: nil

  defp read_file_safe(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} when byte_size(content) > 0 -> content
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp run_detail_events(run_detail) when is_map(run_detail) do
    attempt_dir =
      case get_in(run_detail, ["metadata", "attempt_dir"]) do
        dir when is_binary(dir) -> dir
        _ -> nil
      end

    if attempt_dir do
      attempt_dir
      |> Path.join("events.jsonl")
      |> read_events_jsonl()
    else
      []
    end
  end

  defp run_detail_events(_), do: []

  # -- Story Detail Section --

  attr :story, :map, default: nil
  attr :story_id, :string, default: nil
  attr :run_detail, :map, default: nil
  attr :run_detail_panel_tab, :string, default: "logs"
  attr :reports_tab, :string, default: "review"
  attr :active_prompt_tab, :string, default: "agent"
  attr :active_log_tab, :string, default: "agent"
  attr :story_detail_tab, :string, default: "details"
  attr :settings_edit_mode, :boolean, default: false
  attr :project, Project, required: true
  attr :stories_view, :string, default: @default_stories_view
  attr :story_attempts, :list, default: []
  attr :selected_attempt, :string, default: nil
  attr :preview_session, :map, default: nil

  defp story_detail_section(assigns) do
    snapshot =
      if is_map(assigns.run_detail),
        do: Map.get(assigns.run_detail, "settings_snapshot"),
        else: nil

    run_settings =
      if is_map(assigns.run_detail),
        do: get_in(assigns.run_detail, ["metadata", "run_settings"]) || %{},
        else: %{}

    current_workflow_identity =
      if is_map(assigns.run_detail),
        do: Map.get(assigns.run_detail, "current_workflow_identity"),
        else: %{}

    assigns =
      assigns
      |> assign(:editable, local_provider?(assigns.project))
      |> assign(:settings_snapshot, snapshot)
      |> assign(:run_settings, run_settings)
      |> assign(:current_workflow_identity, current_workflow_identity)
      |> assign(:agent_kind_options, @agent_kind_options)
      |> assign(
        :workflow_fingerprint_status,
        workflow_fingerprint_status(snapshot, current_workflow_identity)
      )

    ~H"""
    <div class="space-y-6">
      <div class="flex items-start justify-between gap-3">
        <div class="flex min-w-0 flex-1 flex-wrap items-center gap-2 sm:gap-3">
          <.link
            navigate={stories_index_path(@project.slug, @stories_view)}
            class="btn btn-ghost btn-sm gap-2 shrink-0"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back to Stories
          </.link>
          <span class="badge badge-outline font-mono text-sm shrink-0">{@story_id}</span>
          <%= if @story do %>
            <div class="shrink-0">
              <.status_badge status={@story["status"] || "open"} />
            </div>
          <% end %>
        </div>

        <%= if @editable && @story do %>
          <% story_id = @story["id"] || @story_id %>
          <% current_status = normalize_status(@story["status"]) %>
          <% status_targets = manual_status_targets(@story["status"]) %>
          <% show_reset = show_reset_action?(current_status) %>
          <% reset_label = reset_action_label(current_status) %>
          <div class="shrink-0">
            <div class="dropdown dropdown-end">
              <label tabindex="0" class="btn btn-ghost btn-sm gap-2 whitespace-nowrap">
                Actions <.icon name="hero-chevron-down" class="size-4" />
              </label>
              <ul
                tabindex="0"
                class="dropdown-content menu menu-xs bg-base-100 rounded-box shadow-lg border border-base-300 z-50 w-44 p-1"
              >
                <li>
                  <button
                    phx-click="open_edit_story_form"
                    phx-value-id={story_id}
                    class="text-xs"
                  >
                    Edit Story
                  </button>
                </li>
                <li>
                  <button
                    phx-click="delete_story"
                    phx-value-id={story_id}
                    onclick={confirm_onclick("Delete #{story_id}? This cannot be undone.")}
                    class="text-xs text-error"
                  >
                    Delete Story
                  </button>
                </li>
                <%= if show_reset do %>
                  <li>
                    <button
                      type="button"
                      phx-click="reset_story"
                      phx-value-id={story_id}
                      class="text-xs text-warning"
                    >
                      {reset_label}
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
        <button
          phx-click="set_story_tab"
          phx-value-tab="settings"
          class={[
            "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
            @story_detail_tab == "settings" && "border-primary text-primary",
            @story_detail_tab != "settings" &&
              "border-transparent text-base-content/60 hover:text-base-content"
          ]}
        >
          Settings
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

            <%= if story_testing_notes(@story) != "" do %>
              <div>
                <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide mb-2">
                  Testing Notes (Tester Only)
                </h3>
                <div class="prose prose-sm max-w-none text-base-content/70">
                  {raw(markdown_to_html(story_testing_notes(@story)))}
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

            <%= if normalize_status(@story["status"]) == "pending_merge" do %>
              <.preview_controls_panel
                story_id={@story["id"] || @story_id}
                project={@project}
                preview_session={@preview_session}
              />
            <% end %>
          </div>
        <% else %>
          <p class="text-base-content/50 text-sm italic">Story not found.</p>
        <% end %>
      <% end %>

      <%= if @story_detail_tab == "runs" do %>
        <div class="flex flex-col gap-4">
          <%= if @selected_attempt do %>
            <div class="flex flex-wrap items-center justify-between gap-2 sm:gap-3">
              <div class="flex flex-wrap items-center gap-2 sm:gap-3">
                <.link
                  navigate={story_runs_tab_path(@project.slug, @story_id, @stories_view)}
                  class="btn btn-ghost btn-sm gap-2"
                >
                  <.icon name="hero-arrow-left" class="size-4" /> All Runs
                </.link>
                <span class="text-sm text-base-content/60">Run {run_number(@selected_attempt)}</span>
                <% retry_action = if @run_detail, do: @run_detail["retry_action"], else: nil %>
              </div>
              <.run_actions_menu retry_action={retry_action} story_id={@story_id} />
            </div>

            <%= if @run_detail && @run_detail["retry_summary"] do %>
              <p class="break-words text-xs text-base-content/60">{@run_detail["retry_summary"]}</p>
            <% end %>

            <%= if @run_detail && run_detail_error(@run_detail) do %>
              <div class="alert alert-error text-sm gap-2">
                <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
                <p class="break-words min-w-0">{run_detail_error(@run_detail)}</p>
              </div>
            <% end %>

            <div class="flex gap-0 border-b border-base-300">
              <%= for {tab, label} <- [
                {"logs", "Logs"},
                {"reports", "Reports"},
                {"prompts", "Prompts"},
                {"settings", "Settings"}
              ] do %>
                <button
                  phx-click="set_run_detail_panel_tab"
                  phx-value-tab={tab}
                  class={[
                    "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
                    @run_detail_panel_tab == tab && "border-primary text-primary",
                    @run_detail_panel_tab != tab &&
                      "border-transparent text-base-content/60 hover:text-base-content"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <%= if @run_detail_panel_tab == "settings" do %>
              <.settings_used_section
                snapshot={@settings_snapshot}
                run_settings={@run_settings}
                current_workflow_identity={@current_workflow_identity}
                workflow_fingerprint_status={@workflow_fingerprint_status}
              />
            <% else %>
              <%= if @run_detail_panel_tab == "prompts" do %>
                <.prompts_section
                  prompts={if(@run_detail, do: @run_detail["prompts"] || %{}, else: %{})}
                  active_prompt_tab={@active_prompt_tab}
                />
              <% else %>
                <%= if @run_detail_panel_tab == "reports" do %>
                  <div class="space-y-4">
                    <div class="flex gap-0 border-b border-base-300">
                      <%= for {tab, label} <- [{"review", "Review"}, {"testing", "Testing"}] do %>
                        <button
                          phx-click="set_reports_tab"
                          phx-value-tab={tab}
                          class={[
                            "px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
                            @reports_tab == tab && "border-primary text-primary",
                            @reports_tab != tab &&
                              "border-transparent text-base-content/60 hover:text-base-content"
                          ]}
                        >
                          {label}
                        </button>
                      <% end %>
                    </div>

                    <%= if @reports_tab == "testing" do %>
                      <.testing_report_section
                        report={if(@run_detail, do: @run_detail["testing_report"])}
                        cycles={if(@run_detail, do: @run_detail["testing_cycles"])}
                        cycle_reports={if(@run_detail, do: @run_detail["testing_cycle_reports"])}
                        project_slug={@project.slug}
                        story_id={@story_id}
                        attempt={if(@run_detail, do: get_in(@run_detail, ["metadata", "attempt"]))}
                      />
                    <% else %>
                      <.review_report_section
                        report={if(@run_detail, do: @run_detail["review_report"])}
                        cycles={if(@run_detail, do: @run_detail["review_cycles"])}
                        cycle_reports={if(@run_detail, do: @run_detail["review_cycle_reports"])}
                      />
                    <% end %>
                  </div>
                <% else %>
                  <div class="flex gap-0 border-b border-base-300">
                    <%= for {tab, label} <- [
                    {"agent", "Agent"},
                    {"review_agent", "Review Agent"},
                    {"testing_agent", "Testing Agent"},
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
                <% end %>
              <% end %>
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
                        <th>Phase</th>
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
                                run_detail_path(
                                  @project.slug,
                                  @story_id,
                                  run.attempt,
                                  @stories_view
                                )
                              }
                              class="font-mono text-sm hover:text-primary"
                            >
                              {run_number(run.attempt)}
                            </.link>
                          </td>
                          <td><.run_status_badge status={run.status} /></td>
                          <td class="text-xs text-base-content/60">{run.phase_label}</td>
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

      <%= if @story_detail_tab == "settings" do %>
        <div class="space-y-4">
          <% execution = get_in(@story, ["settings", "execution"]) || %{} %>
          <% override_fields = [
            {"agent_kind", "Agent Kind", :string},
            {"review_agent_kind", "Review Agent Kind", :string},
            {"review_max_cycles", "Review Max Cycles", :integer},
            {"testing_enabled", "Testing Enabled", :boolean},
            {"testing_agent_kind", "Testing Agent Kind", :string},
            {"testing_max_cycles", "Testing Max Cycles", :integer},
            {"preview_enabled", "Preview Enabled", :boolean}
          ] %>

          <div class="flex items-center justify-between">
            <h3 class="text-xs font-semibold text-base-content/60 uppercase tracking-wide">
              Execution Overrides
            </h3>
            <%= if @editable && !@settings_edit_mode do %>
              <button
                phx-click="toggle_settings_edit"
                class="btn btn-ghost btn-xs gap-1"
              >
                <.icon name="hero-pencil-square" class="size-3.5" /> Edit Overrides
              </button>
            <% end %>
          </div>

          <%= if @settings_edit_mode do %>
            <form phx-submit="save_story_overrides">
              <div class="grid gap-3">
                <%= for {key, label, type} <- override_fields do %>
                  <% value = override_form_value(execution, key) %>
                  <div class="flex items-center justify-between gap-4 p-3 rounded-lg bg-base-200/30 border border-base-300">
                    <label class="text-sm font-medium shrink-0">{label}</label>
                    <div class="w-48">
                      <%= cond do %>
                        <% type == :boolean -> %>
                          <select
                            name={"overrides[#{key}]"}
                            class="select select-bordered select-sm w-full"
                          >
                            <option value="" selected={value == ""}>
                              Use workflow default
                            </option>
                            <option value="true" selected={value == "true"}>
                              Enabled
                            </option>
                            <option value="false" selected={value == "false"}>
                              Disabled
                            </option>
                          </select>
                        <% type == :string -> %>
                          <select
                            name={"overrides[#{key}]"}
                            class="select select-bordered select-sm w-full"
                          >
                            <option value="" selected={value == ""}>
                              Use workflow default
                            </option>
                            <%= for kind <- @agent_kind_options do %>
                              <option value={kind} selected={value == kind}>
                                {kind}
                              </option>
                            <% end %>
                          </select>
                        <% type == :integer -> %>
                          <input
                            type="number"
                            min="1"
                            name={"overrides[#{key}]"}
                            value={value}
                            class="input input-bordered input-sm w-full"
                            placeholder="Use workflow default"
                          />
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
              <div class="flex justify-end gap-2 mt-4">
                <button
                  type="button"
                  phx-click="toggle_settings_edit"
                  class="btn btn-ghost btn-sm"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary btn-sm">
                  Save
                </button>
              </div>
            </form>
          <% else %>
            <div class="grid gap-2">
              <%= for {key, label, type} <- override_fields do %>
                <% has_override = Map.has_key?(execution, key) %>
                <% value = Map.get(execution, key) %>
                <div class={[
                  "flex items-center justify-between p-3 rounded-lg",
                  has_override && "bg-base-200/50 border border-base-300",
                  !has_override && "bg-base-200/20"
                ]}>
                  <div class="flex items-center gap-2">
                    <span class={[
                      "text-sm",
                      has_override && "font-medium",
                      !has_override && "text-base-content/50"
                    ]}>
                      {label}
                    </span>
                    <%= if has_override do %>
                      <span class="badge badge-xs badge-primary">overridden</span>
                    <% end %>
                  </div>
                  <div>
                    <%= cond do %>
                      <% !has_override -> %>
                        <span class="text-xs text-base-content/40">workflow default</span>
                      <% type == :boolean and value -> %>
                        <span class="badge badge-success badge-sm">enabled</span>
                      <% type == :boolean -> %>
                        <span class="badge badge-ghost badge-sm">disabled</span>
                      <% true -> %>
                        <span class="text-sm text-base-content/80">{value}</span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # -- Settings Section --

  attr :project, Project, required: true
  attr :workflow, :map, required: true
  attr :orchestrator_status, :map, default: nil
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

            <div class="sm:col-span-2">
              <span class="text-sm text-base-content/60">Repository</span>
              <p class="font-medium font-mono text-sm break-all">
                {@project.repository || "—"}
              </p>
            </div>
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
                      <span class="label-text text-sm">Max Agents</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      name="settings[agent][max_concurrent_agents]"
                      value={get_in(@workflow.parsed, ["agent", "max_concurrent_agents"]) || 1}
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
                  <div class="sm:col-span-2 lg:col-span-3 flex items-center gap-2">
                    <input type="hidden" name="settings[agent][retries_enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[agent][retries_enabled]"
                      value="true"
                      checked={get_in(@workflow.parsed, ["agent", "retries_enabled"]) == true}
                      class="toggle toggle-sm"
                    />
                    <span class="text-sm">Enable retries</span>
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
                    <div class="pt-5">
                      <div class="flex items-center gap-2">
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
                          aria-describedby="checks-fail-fast-help"
                        />
                        <span class="text-sm">Fail fast</span>
                      </div>
                      <p id="checks-fail-fast-help" class="text-xs text-base-content/60 mt-1">
                        When enabled, checks stop at the first failure. When disabled, all
                        configured checks run so every failure is reported in one cycle.
                      </p>
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

              <%!-- Testing --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Testing
                </p>
                <div class="grid sm:grid-cols-2 gap-4">
                  <div class="sm:col-span-2 flex items-center gap-2">
                    <input
                      type="hidden"
                      name="settings[quality][testing][enabled]"
                      value="false"
                    />
                    <input
                      type="checkbox"
                      name="settings[quality][testing][enabled]"
                      value="true"
                      checked={get_in(@workflow.parsed, ["quality", "testing", "enabled"]) == true}
                      class="toggle toggle-sm toggle-primary"
                    />
                    <span class="text-sm">Enable testing</span>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">Max Cycles</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      max="10"
                      name="settings[quality][testing][max_cycles]"
                      value={
                        get_in(@workflow.parsed, ["quality", "testing", "max_cycles"]) ||
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
                      name="settings[quality][testing][timeout_ms]"
                      value={
                        get_in(@workflow.parsed, ["quality", "testing", "timeout_ms"]) ||
                          7_200_000
                      }
                      class="input input-bordered input-sm w-full"
                    />
                  </div>

                  <%!-- Testing Agent --%>
                  <div class="sm:col-span-2 pt-2">
                    <p class="text-xs font-medium text-base-content/50 mb-3">
                      Testing Agent
                    </p>
                    <div class="space-y-4">
                      <div class="flex items-center gap-2">
                        <input
                          type="hidden"
                          name="settings[quality][testing][agent_custom]"
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name="settings[quality][testing][agent_custom]"
                          value="true"
                          checked={get_in(@workflow.parsed, ["quality", "testing", "agent"]) != nil}
                          class="toggle toggle-sm"
                        />
                        <span class="text-sm">Use a different agent for testing</span>
                      </div>
                      <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
                        <div>
                          <label class="label pb-1">
                            <span class="label-text text-sm">Kind</span>
                          </label>
                          <select
                            name="settings[quality][testing][agent][kind]"
                            class="select select-bordered select-sm w-full"
                          >
                            <%= for k <- ["amp", "claude", "cursor", "opencode", "pi"] do %>
                              <option
                                value={k}
                                selected={
                                  (get_in(@workflow.parsed, [
                                     "quality",
                                     "testing",
                                     "agent",
                                     "kind"
                                   ]) ||
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
                            name="settings[quality][testing][agent][timeout_ms]"
                            value={
                              get_in(@workflow.parsed, [
                                "quality",
                                "testing",
                                "agent",
                                "timeout_ms"
                              ]) ||
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
                            name="settings[quality][testing][agent][command]"
                            value={
                              get_in(@workflow.parsed, [
                                "quality",
                                "testing",
                                "agent",
                                "command"
                              ]) || ""
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

              <%!-- Preview --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Preview
                </p>
                <div class="grid sm:grid-cols-2 gap-4">
                  <div class="sm:col-span-2 flex items-center gap-2">
                    <input type="hidden" name="settings[preview][enabled]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[preview][enabled]"
                      value="true"
                      checked={get_in(@workflow.parsed, ["preview", "enabled"]) == true}
                      class="toggle toggle-sm toggle-primary"
                    />
                    <span class="text-sm">Enable preview</span>
                  </div>
                  <div>
                    <label class="label pb-1">
                      <span class="label-text text-sm">TTL (minutes)</span>
                    </label>
                    <input
                      type="number"
                      min="1"
                      name="settings[preview][ttl_minutes]"
                      value={get_in(@workflow.parsed, ["preview", "ttl_minutes"]) || 120}
                      class="input input-bordered input-sm w-full"
                    />
                  </div>
                </div>
              </div>

              <div class="divider my-0"></div>

              <%!-- Runtime --%>
              <div>
                <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wide mb-3">
                  Runtime
                </p>
                <div class="grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
                  <div>
                    <label class="label pb-1"><span class="label-text text-sm">Kind</span></label>
                    <select
                      name="settings[runtime][kind]"
                      class="select select-bordered select-sm w-full"
                    >
                      <%= for k <- ["host", "docker"] do %>
                        <option
                          value={k}
                          selected={(get_in(@workflow.parsed, ["runtime", "kind"]) || "host") == k}
                        >
                          {k}
                        </option>
                      <% end %>
                    </select>
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
                      <%= for v <- ["push", "merge", "pr"] do %>
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
    <span class={"badge badge-sm whitespace-nowrap #{@color}"}>{display_status(@status)}</span>
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
    <span class={"badge badge-sm whitespace-nowrap #{@color}"}>{@label}</span>
    """
  end

  defp show_run_detail_phase_label?(phase_label) when is_binary(phase_label) do
    phase_label
    |> String.trim()
    |> case do
      "" -> false
      "Run finished" -> false
      _other -> true
    end
  end

  defp show_run_detail_phase_label?(_phase_label), do: false

  defp run_detail_error(run_detail) when is_map(run_detail) do
    error =
      get_in(run_detail, ["metadata", "error"]) ||
        get_in(run_detail, ["error"])

    case error do
      nil -> nil
      "nil" -> nil
      "" -> nil
      msg when is_binary(msg) -> msg
      _ -> nil
    end
  end

  defp run_detail_error(_run_detail), do: nil

  defp show_recent_activity_phase_label?(run) when is_map(run) do
    phase_label = Map.get(run, :phase_label) || Map.get(run, "phase_label")
    status = normalize_run_status(Map.get(run, :status) || Map.get(run, "status"))

    show_run_detail_phase_label?(phase_label) and
      status not in ["ok", "finished", "failed", "stopped"]
  end

  defp show_recent_activity_phase_label?(_run), do: false

  defp normalize_run_status(status) when is_atom(status),
    do: status |> Atom.to_string() |> normalize_run_status()

  defp normalize_run_status(status) when is_binary(status),
    do: status |> String.trim() |> String.downcase()

  defp normalize_run_status(_status), do: ""

  attr :retry_action, :map, default: nil
  attr :story_id, :string, required: true

  defp run_actions_menu(assigns) do
    retry_action = if is_map(assigns.retry_action), do: assigns.retry_action, else: %{}
    retry_label = Map.get(retry_action, "label", "Retry unavailable for this run")
    retry_reason = Map.get(retry_action, "reason")
    retry_enabled = Map.get(retry_action, "enabled", false) == true
    has_retry_action = retry_action != %{}

    assigns =
      assigns
      |> assign(:retry_action, retry_action)
      |> assign(:retry_label, retry_label)
      |> assign(:retry_reason, retry_reason)
      |> assign(:retry_enabled, retry_enabled)
      |> assign(:has_retry_action, has_retry_action)

    ~H"""
    <div class="dropdown dropdown-end">
      <label tabindex="0" class="btn btn-ghost btn-sm gap-2 whitespace-nowrap">
        Actions <.icon name="hero-chevron-down" class="size-4" />
      </label>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-xs z-50 w-52 rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
      >
        <li>
          <%= if @has_retry_action do %>
            <button
              type="button"
              phx-click="trigger_run"
              phx-value-story_id={@story_id}
              phx-value-attempt={@retry_action["attempt"]}
              phx-value-step={@retry_action["step"]}
              disabled={!@retry_enabled}
              title={@retry_reason || @retry_label}
              class={[
                "text-left text-xs",
                @retry_enabled && "text-primary",
                !@retry_enabled && "opacity-60"
              ]}
            >
              {@retry_label}
            </button>
          <% else %>
            <span class="block px-3 py-2 text-left text-xs opacity-60">{@retry_label}</span>
          <% end %>
        </li>
      </ul>
    </div>
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
            <span class="text-base-content/70">({run.run_phase_label})</span>
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

  defp local_tracker_path(%Project{provider: :local} = project) do
    path = Projects.tracker_path(project)

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, "This project does not have a tracker path configured."}

      true ->
        {:ok, path}
    end
  end

  defp local_tracker_path(%Project{}),
    do: {:error, "Story editing is only available for local tracker projects."}

  defp local_tracker_path(_project), do: {:error, "No project selected."}

  defp trigger_full_rerun(project, story_id) do
    with {:ok, tracker_path} <- local_tracker_path(project) do
      case PrdJson.update_story(tracker_path, story_id, %{"status" => "open"}) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_preview_for_story(project, story_id) do
    alias Kollywood.PreviewSessionManager

    with true <- is_map(project) or {:error, "no project selected"},
         {:ok, config, _prompt_template} <- load_project_config(project),
         {:ok, workspace_path} <- find_story_workspace_path(project, story_id) do
      workspace_key =
        story_id
        |> to_string()
        |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
        |> String.trim("-")

      PreviewSessionManager.start_preview(project.slug, story_id,
        config: config,
        workspace_path: workspace_path,
        workspace_key: workspace_key
      )
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, "no project selected"}
    end
  end

  defp merge_pending_story(project, story_id) do
    alias Kollywood.AgentRunner

    with true <- is_map(project) or {:error, "no project selected"},
         {:ok, config, _prompt_template} <- load_project_config(project),
         {:ok, workspace_path} <- find_story_workspace_path(project, story_id),
         {:ok, tracker_path} <- local_tracker_path(project),
         {:ok, stories} <- PrdJson.list_stories(tracker_path),
         story when is_map(story) <- Enum.find(stories, &(&1["id"] == story_id)) do
      issue = %{id: story_id, identifier: story_id, title: story["title"] || story_id}

      branch_prefix =
        get_in(config, [Access.key(:workspace, %{}), Access.key(:branch_prefix, "kollywood/")])

      workspace = %Kollywood.Workspace{
        path: workspace_path,
        key: story_id,
        root: Path.dirname(workspace_path),
        strategy: :worktree,
        branch: "#{branch_prefix}#{story_id}"
      }

      AgentRunner.merge_pending_story(config, issue, workspace)
    else
      nil -> {:error, "story not found"}
      {:error, reason} -> {:error, reason}
      false -> {:error, "no project selected"}
    end
  end

  defp load_project_config(project) do
    path = Projects.workflow_path(project)

    cond do
      not is_binary(path) ->
        {:error, "workflow path unavailable"}

      not File.exists?(path) ->
        {:error, "workflow file not found"}

      true ->
        case File.read(path) do
          {:ok, content} ->
            case Kollywood.Config.parse(content) do
              {:ok, config, prompt_template} ->
                config = %{config | project_provider: normalize_provider(project)}
                {:ok, config, prompt_template}

              {:error, reason} ->
                {:error, reason}
            end

          {:error, reason} ->
            {:error, "failed to read workflow: #{inspect(reason)}"}
        end
    end
  end

  defp find_story_workspace_path(project, story_id) do
    workspace_root = Kollywood.ServiceConfig.project_workspace_root(project.slug)

    workspace_key =
      story_id |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "-") |> String.trim("-")

    path = Path.join(workspace_root, workspace_key)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, "workspace not found at #{path}"}
    end
  end

  defp normalize_provider(%{provider: provider}) when provider in [:github, :gitlab, :local],
    do: provider

  defp normalize_provider(%{provider: "github"}), do: :github
  defp normalize_provider(%{provider: "gitlab"}), do: :gitlab
  defp normalize_provider(%{provider: "local"}), do: :local
  defp normalize_provider(_project), do: :local

  defp default_story_form_values(stories) when is_list(stories) do
    %{
      "id" => suggested_story_id(stories),
      "title" => "",
      "description" => "",
      "acceptanceCriteria" => "",
      "priority" => to_string(next_story_priority(stories)),
      "status" => "draft",
      "dependsOn" => "",
      "notes" => "",
      "testingNotes" => "",
      "execution_agent_kind" => "",
      "execution_review_agent_kind" => "",
      "execution_review_max_cycles" => "",
      "execution_testing_enabled" => "",
      "execution_testing_agent_kind" => "",
      "execution_testing_max_cycles" => ""
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
      "notes" => to_string(Map.get(story, "notes", "")),
      "testingNotes" => story_testing_notes(story),
      "execution_agent_kind" => story_execution_override_value(story, "agent_kind"),
      "execution_review_agent_kind" => story_execution_override_value(story, "review_agent_kind"),
      "execution_review_max_cycles" => story_execution_override_value(story, "review_max_cycles"),
      "execution_testing_enabled" => story_execution_override_value(story, "testing_enabled"),
      "execution_testing_agent_kind" =>
        story_execution_override_value(story, "testing_agent_kind"),
      "execution_testing_max_cycles" =>
        story_execution_override_value(story, "testing_max_cycles")
    }
  end

  defp story_to_form_values(_story), do: default_story_form_values([])

  defp story_execution_override_value(story, key) when is_map(story) and is_binary(key) do
    execution =
      story
      |> Map.get("settings", %{})
      |> Map.get("execution", %{})

    camel_key =
      case key do
        "agent_kind" -> "agentKind"
        "review_agent_kind" -> "reviewAgentKind"
        "review_max_cycles" -> "reviewMaxCycles"
        "testing_enabled" -> "testingEnabled"
        "testing_agent_kind" -> "testingAgentKind"
        "testing_max_cycles" -> "testingMaxCycles"
        other -> other
      end

    value = Map.get(execution, key) || Map.get(execution, camel_key)

    cond do
      is_binary(value) -> value
      is_integer(value) -> Integer.to_string(value)
      is_boolean(value) -> if(value, do: "true", else: "false")
      true -> ""
    end
  end

  defp story_execution_override_value(_story, _key), do: ""

  defp override_form_value(execution, key) when is_map(execution) do
    value = Map.get(execution, key)

    cond do
      is_binary(value) -> value
      is_integer(value) -> Integer.to_string(value)
      is_boolean(value) -> if(value, do: "true", else: "false")
      true -> ""
    end
  end

  defp override_form_value(_execution, _key), do: ""

  defp build_override_settings(params) when is_map(params) do
    execution =
      params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    %{"execution" => execution}
  end

  defp build_override_settings(_params), do: %{"execution" => %{}}

  defp normalize_story_form_params(params) when is_map(params) do
    %{
      "id" => Map.get(params, "id"),
      "title" => Map.get(params, "title"),
      "description" => Map.get(params, "description"),
      "acceptanceCriteria" => Map.get(params, "acceptanceCriteria"),
      "priority" => Map.get(params, "priority"),
      "status" => Map.get(params, "status"),
      "dependsOn" => Map.get(params, "dependsOn"),
      "notes" => Map.get(params, "notes"),
      "testingNotes" => Map.get(params, "testingNotes"),
      "settings" => %{
        "execution" => %{
          "agent_kind" => Map.get(params, "execution_agent_kind"),
          "review_agent_kind" => Map.get(params, "execution_review_agent_kind"),
          "review_max_cycles" => Map.get(params, "execution_review_max_cycles"),
          "testing_enabled" => Map.get(params, "execution_testing_enabled"),
          "testing_agent_kind" => Map.get(params, "execution_testing_agent_kind"),
          "testing_max_cycles" => Map.get(params, "execution_testing_max_cycles")
        }
      },
      "execution_agent_kind" => Map.get(params, "execution_agent_kind"),
      "execution_review_agent_kind" => Map.get(params, "execution_review_agent_kind"),
      "execution_review_max_cycles" => Map.get(params, "execution_review_max_cycles"),
      "execution_testing_enabled" => Map.get(params, "execution_testing_enabled"),
      "execution_testing_agent_kind" => Map.get(params, "execution_testing_agent_kind"),
      "execution_testing_max_cycles" => Map.get(params, "execution_testing_max_cycles")
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
        "notes",
        "testingNotes",
        "execution_agent_kind",
        "execution_review_agent_kind",
        "execution_review_max_cycles",
        "execution_testing_enabled",
        "execution_testing_agent_kind",
        "execution_testing_max_cycles"
      ])
    )
  end

  defp merge_story_form_values(_existing, attrs) when is_map(attrs), do: attrs
  defp merge_story_form_values(existing, _attrs) when is_map(existing), do: existing
  defp merge_story_form_values(_existing, _attrs), do: %{}

  defp story_testing_notes(story) when is_map(story) do
    value = Map.get(story, "testingNotes") || Map.get(story, "testing_notes")

    case value do
      notes when is_binary(notes) -> notes
      _other -> ""
    end
  end

  defp story_testing_notes(_story), do: ""

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
      project = socket.assigns[:current_project]
      story = Enum.find(socket.assigns.stories, &(&1["id"] == story_id))

      preview_session =
        if project && story_id do
          Kollywood.PreviewSessionManager.get_session(project.slug, story_id)
        else
          nil
        end

      socket
      |> assign(:selected_story, story)
      |> assign(:preview_session, preview_session)
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

  defp update_story_status(socket, id, status, success_message \\ "Story status updated.") do
    project = socket.assigns.current_project

    if project && status in ["cancelled", "draft", "open", "done", "failed"] do
      Kollywood.PreviewSessionManager.stop_if_active(project.slug, id)
    end

    case local_tracker_path(project) do
      {:ok, tracker_path} ->
        case PrdJson.set_manual_status(tracker_path, id, status) do
          :ok ->
            socket
            |> load_project_data(project)
            |> sync_story_detail_selection()
            |> put_flash(:info, success_message)

          {:error, reason} ->
            put_flash(socket, :error, "Status update failed: #{reason}")
        end

      {:error, reason} ->
        put_flash(socket, :error, reason)
    end
  end

  defp validate_manual_story_transition(stories, id, from_status, to_status)
       when is_list(stories) and is_binary(id) do
    case Enum.find(stories, &(&1["id"] == id)) do
      nil ->
        {:error, "Story not found: #{id}"}

      story ->
        current_status = normalize_status(story["status"])
        normalized_from_status = normalize_optional_status(from_status)
        normalized_to_status = normalize_optional_status(to_status)
        allowed_statuses = manual_status_targets(current_status)
        allowed_display = format_allowed_statuses(allowed_statuses)

        cond do
          normalized_to_status in [nil, ""] ->
            {:error, "Target status is required."}

          normalized_from_status && normalized_from_status != current_status ->
            {:error,
             "Story #{id} changed from #{display_status(normalized_from_status)} to #{display_status(current_status)}. Try dragging again."}

          normalized_to_status == current_status ->
            {:error, "Story #{id} is already #{display_status(current_status)}."}

          normalized_to_status in allowed_statuses ->
            {:ok, normalized_to_status}

          true ->
            {:error,
             "Cannot move #{id} from #{display_status(current_status)} to #{display_status(normalized_to_status)}. Allowed: #{allowed_display}"}
        end
    end
  end

  defp validate_manual_story_transition(_stories, id, _from_status, _to_status)
       when is_binary(id),
       do: {:error, "Story not found: #{id}"}

  defp validate_manual_story_transition(_stories, _id, _from_status, _to_status),
    do: {:error, "Story ID is required."}

  defp format_allowed_statuses(statuses) when is_list(statuses) and statuses != [] do
    Enum.map_join(statuses, ", ", &display_status/1)
  end

  defp format_allowed_statuses(_statuses), do: "none"

  defp normalize_optional_status(status) when is_binary(status) do
    case normalize_status(status) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_status(_status), do: nil

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

  @status_group_order @story_status_order

  defp read_stories(project) do
    path = Projects.tracker_path(project)

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
            attempt_dir = Path.join(story_dir, attempt_dir_name)

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

            phase = derive_phase_map(attempt_dir, metadata)
            retry_mode = normalize_retry_mode(Map.get(metadata, "retry_mode"))
            retry_provenance = normalize_retry_provenance(Map.get(metadata, "retry_provenance"))

            %{
              story_id: story_dir_name,
              attempt: attempt_num,
              status: metadata["status"] || "unknown",
              started_at: metadata["started_at"],
              ended_at: metadata["ended_at"],
              error: metadata["error"],
              retry_mode: retry_mode,
              retry_mode_label: retry_mode_label(retry_mode),
              retry_provenance: retry_provenance,
              retry_summary: retry_summary(retry_mode, retry_provenance),
              phase: phase,
              phase_label: RunPhase.label(phase)
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

  defp latest_run_by_story_id(run_attempts) when is_list(run_attempts) do
    run_attempts
    |> Enum.sort_by(&run_attempt_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn run, acc -> Map.put_new(acc, run.story_id, run) end)
  end

  defp latest_run_by_story_id(_run_attempts), do: %{}

  defp run_attempt_sort_key(run) when is_map(run) do
    {run.ended_at || run.started_at || "", run.attempt || 0}
  end

  defp run_attempt_sort_key(_run), do: {"", 0}

  defp normalize_retry_mode(mode)
       when mode in [:agent_continuation, "agent_continuation", "agent-continuation"] do
    "agent_continuation"
  end

  defp normalize_retry_mode(mode) when mode in [:full_rerun, "full_rerun", "full-rerun"] do
    "full_rerun"
  end

  defp normalize_retry_mode(_mode), do: "full_rerun"

  defp normalize_retry_provenance(provenance) when is_map(provenance), do: provenance
  defp normalize_retry_provenance(_provenance), do: %{}

  defp retry_mode_label("agent_continuation"), do: "Agent continuation"
  defp retry_mode_label(_mode), do: "Full rerun"

  defp retry_summary("agent_continuation", provenance) when is_map(provenance) do
    originating_attempt =
      provenance
      |> map_field(:originating_attempt)
      |> positive_integer_or_nil()

    last_successful_turn =
      provenance
      |> map_field(:last_successful_turn)
      |> positive_integer_or_nil()

    failure_reason =
      provenance
      |> map_field(:failure_reason)
      |> compact_reason()

    detail_parts =
      [
        originating_attempt && "run ##{originating_attempt}",
        last_successful_turn && "turn #{last_successful_turn}"
      ]
      |> Enum.reject(&is_nil/1)

    details =
      case detail_parts do
        [] -> nil
        parts -> "from " <> Enum.join(parts, ", ")
      end

    cond do
      details && failure_reason -> "#{details} (#{failure_reason})"
      details -> details
      failure_reason -> failure_reason
      true -> nil
    end
  end

  defp retry_summary(_mode, _provenance), do: nil

  defp map_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_field(_map, _key), do: nil

  defp positive_integer_or_nil(value) when is_integer(value) and value > 0, do: value

  defp positive_integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> nil
    end
  end

  defp positive_integer_or_nil(_value), do: nil

  defp compact_reason(reason) when is_binary(reason) do
    trimmed = String.trim(reason)

    cond do
      trimmed == "" ->
        nil

      String.length(trimmed) > 80 ->
        String.slice(trimmed, 0, 80) <> "..."

      true ->
        trimmed
    end
  end

  defp compact_reason(_reason), do: nil

  defp derive_phase_map(attempt_dir, metadata) when is_binary(attempt_dir) and is_map(metadata) do
    status_phase = RunPhase.from_status(metadata["status"])

    events =
      attempt_dir
      |> Path.join("events.jsonl")
      |> read_events_jsonl()

    RunPhase.from_events(events, initial_phase: status_phase)
  end

  defp derive_phase_map(_attempt_dir, metadata) when is_map(metadata) do
    RunPhase.from_status(metadata["status"])
  end

  defp derive_phase_map(_attempt_dir, _metadata), do: RunPhase.unknown()

  defp read_events_jsonl(path) when is_binary(path) do
    if File.exists?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce([], fn line, acc ->
        case Jason.decode(String.trim(line)) do
          {:ok, event} when is_map(event) -> [event | acc]
          _other -> acc
        end
      end)
      |> Enum.reverse()
    else
      []
    end
  rescue
    _ -> []
  end

  defp read_events_jsonl(_path), do: []
  # -- Settings Helpers --

  @workflow_yaml_key_order ~w(tracker workspace agent quality preview runtime hooks publish git)

  defp apply_settings(parsed, settings) do
    agent_p = Map.get(settings, "agent", %{})
    workspace_p = Map.get(settings, "workspace", %{})
    quality_p = Map.get(settings, "quality", %{})
    checks_p = Map.get(quality_p, "checks", %{})
    review_p = Map.get(quality_p, "review", %{})
    testing_p = Map.get(quality_p, "testing", %{})
    preview_p = Map.get(settings, "preview", %{})
    runtime_p = Map.get(settings, "runtime", %{})
    publish_p = Map.get(settings, "publish", %{})
    git_p = Map.get(settings, "git", %{})

    existing_agent = Map.get(parsed, "agent", %{})
    existing_quality = Map.get(parsed, "quality", %{})
    existing_checks = Map.get(existing_quality, "checks", %{})
    existing_review = Map.get(existing_quality, "review", %{})
    existing_testing = Map.get(existing_quality, "testing", %{})

    command = String.trim(Map.get(agent_p, "command", ""))

    new_agent =
      existing_agent
      |> Map.put("kind", Map.get(agent_p, "kind", Map.get(existing_agent, "kind", "amp")))
      |> Map.put(
        "max_turns",
        parse_form_int(agent_p, "max_turns", Map.get(existing_agent, "max_turns", 20))
      )
      |> Map.put(
        "max_concurrent_agents",
        parse_form_int(
          agent_p,
          "max_concurrent_agents",
          Map.get(existing_agent, "max_concurrent_agents", 1)
        )
      )
      |> Map.put(
        "timeout_ms",
        parse_form_int(agent_p, "timeout_ms", Map.get(existing_agent, "timeout_ms", 7_200_000))
      )
      |> Map.put(
        "retries_enabled",
        parse_form_bool(
          agent_p,
          "retries_enabled",
          Map.get(existing_agent, "retries_enabled", false)
        )
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
          )
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

    existing_testing_prompt_template = get_in(parsed, ["quality", "testing", "prompt_template"])
    testing_agent_custom = Map.get(testing_p, "agent_custom") == "true"
    testing_agent_p = Map.get(testing_p, "agent", %{})

    new_testing =
      %{
        "enabled" => Map.get(testing_p, "enabled") == "true",
        "max_cycles" =>
          parse_form_int(
            testing_p,
            "max_cycles",
            Map.get(existing_testing, "max_cycles", quality_max_cycles)
          ),
        "timeout_ms" =>
          parse_form_int(
            testing_p,
            "timeout_ms",
            Map.get(existing_testing, "timeout_ms", 7_200_000)
          )
      }
      |> then(fn t ->
        if is_binary(existing_testing_prompt_template) and existing_testing_prompt_template != "",
          do: Map.put(t, "prompt_template", existing_testing_prompt_template),
          else: t
      end)
      |> then(fn t ->
        if testing_agent_custom do
          testing_agent_command = String.trim(Map.get(testing_agent_p, "command", ""))

          testing_agent =
            %{"kind" => Map.get(testing_agent_p, "kind", "claude")}
            |> Map.put(
              "timeout_ms",
              parse_form_int(
                testing_agent_p,
                "timeout_ms",
                Map.get(existing_testing, "agent", %{}) |> Map.get("timeout_ms", 7_200_000)
              )
            )
            |> then(fn a ->
              if testing_agent_command != "",
                do: Map.put(a, "command", testing_agent_command),
                else: a
            end)

          Map.put(t, "agent", testing_agent)
        else
          Map.delete(t, "agent")
        end
      end)

    existing_preview = Map.get(parsed, "preview", %{})

    new_preview =
      %{
        "enabled" => Map.get(preview_p, "enabled") == "true",
        "ttl_minutes" =>
          parse_form_int(preview_p, "ttl_minutes", Map.get(existing_preview, "ttl_minutes", 120))
      }

    new_quality = %{
      "max_cycles" => quality_max_cycles,
      "checks" => new_checks,
      "review" => new_review,
      "testing" => new_testing
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

    existing_runtime = Map.get(parsed, "runtime", %{})

    new_runtime =
      existing_runtime
      |> Map.delete("profile")
      |> Map.delete("full_stack")
      |> Map.put("kind", Map.get(runtime_p, "kind", Map.get(existing_runtime, "kind", "host")))

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
    |> Map.put("preview", new_preview)
    |> Map.put("runtime", new_runtime)
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

  defp parse_form_bool(params, key, default) do
    case Map.get(params, key) do
      nil ->
        default

      value when value in [true, "true", "1", "yes", "on"] ->
        true

      _other ->
        false
    end
  end

  defp local_provider?(%{provider: "local"}), do: true
  defp local_provider?(%{provider: :local}), do: true
  defp local_provider?(_), do: false

  defp git_commit_workflow(workflow_path) when is_binary(workflow_path) do
    repo_dir = Path.dirname(workflow_path)

    {root_out, root_status} =
      System.cmd("git", ["rev-parse", "--show-toplevel"],
        cd: repo_dir,
        stderr_to_stdout: true
      )

    if root_status != 0 do
      Logger.warning("Failed to resolve git root for #{workflow_path}: #{String.trim(root_out)}")

      :ok
    else
      repo_root = String.trim(root_out)
      workflow_file = Path.relative_to(workflow_path, repo_root)

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
    end

    :ok
  rescue
    error ->
      Logger.warning("Failed to commit workflow after settings save: #{inspect(error)}")
      :ok
  end

  defp workflow_path(nil), do: nil

  defp workflow_path(project) do
    Projects.workflow_path(project)
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
    config =
      case Kollywood.WorkflowStore.get_config() do
        %{} = workflow_config -> workflow_config
        _other -> fallback_workspace_cleanup_config(project)
      end

    if is_map(config) do
      hooks = Map.get(config, :hooks, %{})
      _ = Kollywood.Workspace.cleanup_for_issue(story_id, config, hooks)
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

  defp fallback_workspace_cleanup_config(project) do
    slug =
      project
      |> Map.get(:slug)
      |> case do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        _other ->
          nil
      end

    if is_binary(slug) do
      %{
        workspace: %{
          root: ServiceConfig.project_workspace_root(slug),
          source: ServiceConfig.project_repos_path(slug),
          strategy: :worktree,
          branch_prefix: "kollywood/"
        },
        hooks: %{}
      }
    else
      nil
    end
  end

  defp stop_orchestrator_issue(issue_id) when is_binary(issue_id) do
    try do
      Kollywood.Orchestrator.stop_issue(issue_id)
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp stop_orchestrator_issue(_issue_id), do: :ok

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

  defp resolve_stories_view(param_view, current_view) do
    cond do
      is_binary(param_view) and String.trim(param_view) != "" ->
        normalize_stories_view(param_view)

      true ->
        normalize_stories_view(current_view)
    end
  end

  defp stories_index_path(project_slug, stories_view) when is_binary(project_slug) do
    query = stories_view_query(stories_view)

    if query == [] do
      ~p"/projects/#{project_slug}/stories"
    else
      ~p"/projects/#{project_slug}/stories?#{query}"
    end
  end

  defp project_overview_path(project_slug, stories_view) when is_binary(project_slug) do
    query = stories_view_query(stories_view)

    if query == [] do
      ~p"/projects/#{project_slug}"
    else
      ~p"/projects/#{project_slug}?#{query}"
    end
  end

  defp project_runs_path(project_slug, stories_view) when is_binary(project_slug) do
    query = stories_view_query(stories_view)

    if query == [] do
      ~p"/projects/#{project_slug}/runs"
    else
      ~p"/projects/#{project_slug}/runs?#{query}"
    end
  end

  defp project_settings_path(project_slug, stories_view) when is_binary(project_slug) do
    query = stories_view_query(stories_view)

    if query == [] do
      ~p"/projects/#{project_slug}/settings"
    else
      ~p"/projects/#{project_slug}/settings?#{query}"
    end
  end

  defp story_detail_path(project_slug, story_id, stories_view, extra_query \\ [])
       when is_binary(project_slug) and is_binary(story_id) and is_list(extra_query) do
    query = merge_view_query(stories_view, extra_query)

    if query == [] do
      ~p"/projects/#{project_slug}/stories/#{story_id}"
    else
      ~p"/projects/#{project_slug}/stories/#{story_id}?#{query}"
    end
  end

  defp story_runs_tab_path(project_slug, story_id, stories_view, extra_query \\ [])
       when is_binary(project_slug) and is_binary(story_id) and is_list(extra_query) do
    query = merge_view_query(stories_view, [{:tab, "runs"} | extra_query])
    ~p"/projects/#{project_slug}/stories/#{story_id}?#{query}"
  end

  defp run_detail_path(project_slug, story_id, attempt, stories_view, extra_query \\ [])
       when is_binary(project_slug) and is_binary(story_id) and is_list(extra_query) do
    query = merge_view_query(stories_view, extra_query)

    if query == [] do
      ~p"/projects/#{project_slug}/runs/#{story_id}/#{attempt}"
    else
      ~p"/projects/#{project_slug}/runs/#{story_id}/#{attempt}?#{query}"
    end
  end

  defp stories_view_query(stories_view) do
    normalized_view = normalize_stories_view(stories_view)

    if normalized_view == @default_stories_view do
      []
    else
      [view: normalized_view]
    end
  end

  defp merge_view_query(stories_view, extra_query) when is_list(extra_query) do
    stories_view_query(stories_view)
    |> Keyword.merge(extra_query, fn _key, _left, right -> right end)
  end

  defp maybe_patch_log_tab(socket, tab) when is_binary(tab) do
    project = socket.assigns[:current_project]
    story_id = socket.assigns[:run_detail_story_id]
    attempt = socket.assigns[:run_detail_attempt]
    stories_view = socket.assigns[:stories_view]
    log_query = log_tab_query(tab)

    case {socket.assigns[:live_action], project, story_id, attempt} do
      {:run_detail, %Project{slug: slug}, story_id, attempt}
      when is_binary(story_id) and not is_nil(attempt) ->
        push_patch(socket, to: run_detail_path(slug, story_id, attempt, stories_view, log_query))

      {:story_detail, %Project{slug: slug}, story_id, attempt}
      when is_binary(story_id) and not is_nil(attempt) ->
        push_patch(
          socket,
          to: story_runs_tab_path(slug, story_id, stories_view, [{:attempt, attempt} | log_query])
        )

      _other ->
        socket
    end
  end

  defp maybe_patch_log_tab(socket, _tab), do: socket

  defp log_tab_query(tab) when is_binary(tab) do
    if tab == "agent" do
      []
    else
      [log_tab: tab]
    end
  end

  defp log_tab_query(_tab), do: []

  defp resolve_active_log_tab(param, current) do
    cond do
      valid_log_tab?(param) -> param
      valid_log_tab?(current) -> current
      true -> "agent"
    end
  end

  defp valid_log_tab?(tab) when is_binary(tab), do: tab in @log_tabs
  defp valid_log_tab?(_tab), do: false

  defp resolve_reports_tab(param, current) do
    cond do
      valid_reports_tab?(param) -> param
      valid_reports_tab?(current) -> current
      true -> "review"
    end
  end

  defp valid_reports_tab?(tab) when is_binary(tab), do: tab in @reports_tabs
  defp valid_reports_tab?(_tab), do: false

  defp maybe_patch_stories_view(socket, stories_view) do
    case socket.assigns do
      %{current_project: %Project{slug: slug}, live_action: :stories} ->
        push_patch(socket, to: stories_index_path(slug, stories_view), replace: true)

      _other ->
        socket
    end
  end

  defp confirmed_action?(params) when is_map(params) do
    case Map.get(params, "confirmed") do
      true -> true
      "true" -> true
      "1" -> true
      1 -> true
      _other -> false
    end
  end

  defp confirmed_action?(_params), do: false

  defp clear_action_confirmation(socket), do: assign(socket, :action_confirmation, nil)

  defp open_reset_confirmation(socket, story_id) when is_binary(story_id) do
    story = Enum.find(socket.assigns[:stories] || [], &(&1["id"] == story_id))
    status = normalize_status(if(is_map(story), do: story["status"], else: nil))
    action_label = reset_action_label(status)

    assign(socket, :action_confirmation, %{
      event: "reset_story",
      id: story_id,
      title: action_label,
      message: reset_action_confirm(status, story_id),
      confirm_label: action_label
    })
  end

  defp open_reset_confirmation(socket, _story_id), do: socket

  defp open_retry_confirmation(socket, params) do
    project = socket.assigns.current_project
    story_id = Map.get(params, "story_id") || socket.assigns.run_detail_story_id

    source_attempt =
      Map.get(params, "attempt") || get_in(socket.assigns, [:run_detail, "metadata", "attempt"])

    retry_step =
      Map.get(params, "step") || get_in(socket.assigns, [:run_detail, "retry_action", "step"])

    step_label = retry_action_label(retry_step)
    attempt_text = retry_attempt_text(source_attempt)

    message =
      case retry_step do
        "full_rerun" ->
          "Reset #{story_id || "this story"} to Open and enqueue a full rerun?"

        _other ->
          "Start #{String.downcase(step_label)} for #{story_id || "this story"}#{attempt_text}? This creates a new linked run attempt."
      end

    assign(socket, :action_confirmation, %{
      event: "trigger_run",
      story_id: story_id,
      attempt: source_attempt,
      step: retry_step,
      title: step_label,
      message: message,
      confirm_label: if(retry_step == "full_rerun", do: "Start full rerun", else: "Start retry"),
      disabled: is_nil(project) or not is_binary(story_id)
    })
  end

  defp retry_action_label("checks"), do: "Retry checks"
  defp retry_action_label("review"), do: "Retry review"
  defp retry_action_label("testing"), do: "Retry testing"
  defp retry_action_label("publish"), do: "Retry publish"
  defp retry_action_label("full_rerun"), do: "Full rerun"

  defp retry_action_label(step) when is_binary(step) and step != "",
    do: "Retry #{String.downcase(step)}"

  defp retry_action_label(_step), do: "Retry run"

  defp retry_attempt_text(source_attempt) do
    case parse_attempt(source_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> " from run ##{attempt}"
      _other -> ""
    end
  end

  defp perform_reset_story(socket, id) do
    project = socket.assigns.current_project

    stop_orchestrator_issue(id)
    if project, do: Kollywood.PreviewSessionManager.stop_if_active(project.slug, id)

    case local_tracker_path(project) do
      {:ok, tracker_path} ->
        case PrdJson.reset_story(tracker_path, id) do
          :ok ->
            cleanup_worktree(project, id)

            socket
            |> assign(:preview_session, nil)
            |> load_project_data(project)
            |> sync_story_detail_selection()
            |> put_flash(:info, "Work stopped and story moved to Draft.")

          {:error, reason} ->
            put_flash(socket, :error, "Reset failed: #{reason}")
        end

      {:error, reason} ->
        put_flash(socket, :error, reason)
    end
  end

  defp perform_trigger_run(socket, params) do
    project = socket.assigns.current_project
    story_id = Map.get(params, "story_id") || socket.assigns.run_detail_story_id

    source_attempt =
      Map.get(params, "attempt") || get_in(socket.assigns, [:run_detail, "metadata", "attempt"])

    retry_step =
      Map.get(params, "step") || get_in(socket.assigns, [:run_detail, "retry_action", "step"])

    cond do
      is_nil(project) ->
        put_flash(socket, :error, "Select a project before retrying a run.")

      not local_provider?(project) ->
        put_flash(socket, :error, "Step retries are only available for local projects.")

      not is_binary(story_id) ->
        put_flash(socket, :error, "No story selected for retry.")

      retry_step == "full_rerun" ->
        case trigger_full_rerun(project, story_id) do
          :ok ->
            socket
            |> load_project_data(project)
            |> sync_story_detail_selection()
            |> put_flash(:info, "Story reset to open. The orchestrator will pick it up.")

          {:error, reason} ->
            put_flash(socket, :error, "Full rerun failed: #{reason}")
        end

      true ->
        start_step_retry_async(socket, project, story_id, source_attempt, retry_step)
    end
  end

  defp start_step_retry_async(socket, %Project{} = project, story_id, source_attempt, retry_step)
       when is_binary(story_id) do
    parent = self()
    project_slug = project.slug

    spawn(fn ->
      result =
        try do
          StepRetry.retry(project, story_id, source_attempt, retry_step)
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, "retry task #{kind}: #{inspect(reason)}"}
        end

      send(
        parent,
        {:step_retry_finished, project_slug, story_id, source_attempt, retry_step, result}
      )
    end)

    socket
    |> load_project_data(project)
    |> sync_story_detail_selection()
    |> put_flash(
      :info,
      "Started #{String.downcase(retry_action_label(retry_step))}. This can take a few minutes."
    )
  end

  defp start_step_retry_async(socket, _project, _story_id, _source_attempt, _retry_step),
    do: socket

  defp handle_step_retry_finished(
         socket,
         %Project{} = project,
         story_id,
         _source_attempt,
         _retry_step,
         {:ok, result}
       ) do
    attempt = parse_attempt(result[:attempt])
    retry_step_label = result[:retry_step] || "step"
    run_label = if is_integer(attempt), do: "##{attempt}", else: "new run"

    socket
    |> load_project_data(project)
    |> sync_story_detail_selection()
    |> maybe_navigate_to_retry_attempt(project, story_id, attempt)
    |> put_flash(:info, "Retry #{retry_step_label} completed as #{run_label}.")
  end

  defp handle_step_retry_finished(
         socket,
         %Project{} = project,
         _story_id,
         _source_attempt,
         _retry_step,
         {:error, reason}
       ) do
    socket
    |> load_project_data(project)
    |> sync_story_detail_selection()
    |> put_flash(:error, "Retry failed: #{reason}")
  end

  defp show_reset_action?(status) do
    normalize_status(status) not in ["open", "draft"]
  end

  defp reset_action_label(status) do
    if normalize_status(status) == "in_progress", do: "Stop Work", else: "Reset Story"
  end

  defp reset_action_confirm(status, story_id) do
    story_id = story_id || "this story"

    if normalize_status(status) == "in_progress" do
      "Stop work on #{story_id}? This will stop any in-progress run, move it to Draft, clear run data, and remove the worktree."
    else
      "Reset #{story_id}? This will move it to Draft, clear run data, and remove the worktree."
    end
  end

  defp confirm_onclick(message) when is_binary(message) and message != "" do
    "return window.confirm(#{Jason.encode!(message)});"
  end

  defp confirm_onclick(_message), do: nil

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

  defp maybe_navigate_to_retry_attempt(socket, _project, _story_id, attempt)
       when not is_integer(attempt) or attempt <= 0 do
    socket
  end

  defp maybe_navigate_to_retry_attempt(socket, project, story_id, attempt) do
    stories_view = socket.assigns[:stories_view]
    log_query = log_tab_query(socket.assigns[:active_log_tab])

    case socket.assigns[:live_action] do
      :run_detail ->
        push_patch(
          socket,
          to: run_detail_path(project.slug, story_id, attempt, stories_view, log_query)
        )

      :story_detail ->
        push_patch(
          socket,
          to:
            story_runs_tab_path(project.slug, story_id, stories_view, [
              {:attempt, attempt} | log_query
            ])
        )

      _other ->
        socket
    end
  end

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
          to: story_runs_tab_path(project.slug, story_id, socket.assigns[:stories_view])
        )
    end
  end

  defp handle_live_action(socket, :step_detail, params) do
    story_id = params["story_id"]
    attempt = params["attempt"]
    step_idx = params["step_idx"]
    project = socket.assigns.current_project

    if project && is_binary(attempt) && is_binary(step_idx) do
      tab = socket.assigns.active_log_tab
      run_detail = load_run_detail_for_attempt(project, story_id, attempt, tab)
      parsed_idx = String.to_integer(step_idx)

      run_in_progress =
        if run_detail,
          do: get_in(run_detail, ["metadata", "status"]) in ["running", "in_progress", "claimed"],
          else: false

      steps =
        if run_detail do
          events = run_detail_events(run_detail)
          Kollywood.Orchestrator.RunSteps.from_events(events, run_in_progress: run_in_progress)
        else
          []
        end

      current_step = Enum.find(steps, &(&1.idx == parsed_idx))

      socket
      |> assign(:run_detail, run_detail)
      |> assign(:step_idx, step_idx)
      |> assign(:current_step, current_step)
      |> assign(:step_detail_tab, "logs")
    else
      socket
      |> assign(:step_idx, nil)
      |> assign(:current_step, nil)
      |> assign(:step_detail_tab, "logs")
    end
  rescue
    _ ->
      socket
      |> assign(:step_idx, nil)
      |> assign(:current_step, nil)
      |> assign(:step_detail_tab, "logs")
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
          build_run_detail(project, story_id, metadata, files, tab)

        {:error, _} ->
          nil
      end
    end)
  end

  defp load_selected_run_detail(socket, tab) do
    project = socket.assigns.current_project
    story_id = socket.assigns.run_detail_story_id
    attempt = socket.assigns.run_detail_attempt

    cond do
      project == nil or not is_binary(story_id) ->
        nil

      is_binary(attempt) and String.trim(attempt) != "" ->
        load_run_detail_for_attempt(project, story_id, attempt, tab)

      true ->
        load_run_detail_latest(project, story_id, tab)
    end
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
            build_run_detail(project, story_id, metadata, files, tab)

          {:error, _} ->
            nil
        end
      end)
    end
  end

  defp build_run_detail(project, story_id, metadata, files, tab) do
    content = read_log_tab_content(files, tab)
    phase = derive_phase_map(Path.dirname(files.metadata), metadata)
    retry_mode = normalize_retry_mode(Map.get(metadata, "retry_mode"))
    retry_provenance = normalize_retry_provenance(Map.get(metadata, "retry_provenance"))
    events = read_events_jsonl(files.events)
    review_report = load_review_report(metadata, files)
    review_cycle_reports = load_review_cycle_reports(files)
    testing_report = load_testing_report(metadata, files)
    testing_cycle_reports = load_testing_cycle_reports(files)
    review_cycles = review_cycle_summaries(events)
    testing_cycles = testing_cycle_summaries(events)
    prompts = extract_captured_prompts(events)

    %{
      "metadata" => Map.put(metadata, "attempt_dir", Path.dirname(files.metadata)),
      "files" => files,
      "settings_snapshot" => RunLogs.settings_snapshot(metadata),
      "current_workflow_identity" => current_workflow_identity(project),
      "phase" => phase,
      "phase_label" => RunPhase.label(phase),
      "retry_mode" => retry_mode,
      "retry_mode_label" => retry_mode_label(retry_mode),
      "retry_provenance" => retry_provenance,
      "retry_summary" => retry_summary(retry_mode, retry_provenance),
      "retry_action" => StepRetry.retry_action(project, story_id, Map.get(metadata, "attempt")),
      "review_report" => review_report,
      "review_cycles" => review_cycles,
      "review_cycle_reports" => review_cycle_reports,
      "testing_report" => testing_report,
      "testing_cycles" => testing_cycles,
      "testing_cycle_reports" => testing_cycle_reports,
      "prompts" => prompts,
      "active_log_content" => content
    }
  end

  defp load_review_report(metadata, files) when is_map(metadata) and is_map(files) do
    metadata_report =
      case Map.get(metadata, "review_report") do
        report when is_map(report) -> normalize_review_report(report)
        _other -> nil
      end

    metadata_report || read_review_report_from_files(files)
  end

  defp load_review_report(_metadata, _files), do: nil

  defp read_review_report_from_files(files) when is_map(files) do
    [Map.get(files, :review_json)]
    |> Enum.find_value(fn path ->
      if is_binary(path) and File.exists?(path) do
        with {:ok, content} <- File.read(path),
             {:ok, decoded} <- Jason.decode(content),
             true <- is_map(decoded) do
          normalize_review_report(decoded)
        else
          _other -> nil
        end
      else
        nil
      end
    end)
  end

  defp read_review_report_from_files(_files), do: nil

  defp load_review_cycle_reports(files) when is_map(files) do
    load_cycle_reports(files, :review_cycles_dir, &normalize_review_report/1)
  end

  defp load_review_cycle_reports(_files), do: []

  defp normalize_review_report(report) when is_map(report) do
    verdict =
      report
      |> map_field(:verdict)
      |> maybe_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    if verdict in ["pass", "fail"] do
      findings =
        report
        |> map_field(:findings)
        |> normalize_review_report_findings()

      %{
        "verdict" => verdict,
        "summary" => maybe_string(map_field(report, :summary)),
        "findings" => findings,
        "raw" => report
      }
    else
      nil
    end
  end

  defp normalize_review_report(_report), do: nil

  defp normalize_review_report_findings(findings) when is_list(findings) do
    findings
    |> Enum.map(&normalize_review_report_finding/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_review_report_findings(_findings), do: []

  defp normalize_review_report_finding(finding) when is_map(finding) do
    description = maybe_string(map_field(finding, :description))

    severity =
      finding
      |> map_field(:severity)
      |> maybe_string()
      |> case do
        nil -> "minor"
        value -> String.downcase(value)
      end

    if is_binary(description) do
      %{
        "severity" => severity,
        "description" => description
      }
    else
      nil
    end
  end

  defp normalize_review_report_finding(_finding), do: nil

  defp review_cycle_summaries(events) when is_list(events) do
    events
    |> Enum.filter(fn event ->
      event_type = map_field(event, :type) |> maybe_string()
      event_type in ["review_passed", "review_failed", "review_error"]
    end)
    |> Enum.map(fn event ->
      event_type = map_field(event, :type) |> maybe_string()

      status =
        case event_type do
          "review_passed" -> "pass"
          "review_failed" -> "fail"
          "review_error" -> "error"
          _other -> "unknown"
        end

      %{
        "cycle" => positive_integer_or_nil(map_field(event, :cycle)),
        "status" => status,
        "summary" =>
          maybe_string(map_field(event, :reason)) ||
            maybe_string(map_field(event, :summary))
      }
    end)
    |> Enum.sort_by(fn item -> {Map.get(item, "cycle") || 0, Map.get(item, "status") || ""} end)
  end

  defp review_cycle_summaries(_events), do: []

  defp testing_cycle_summaries(events) when is_list(events) do
    events
    |> Enum.filter(fn event ->
      event_type = map_field(event, :type) |> maybe_string()
      event_type in ["testing_passed", "testing_failed", "testing_error"]
    end)
    |> Enum.map(fn event ->
      event_type = map_field(event, :type) |> maybe_string()

      status =
        case event_type do
          "testing_passed" -> "pass"
          "testing_failed" -> "fail"
          "testing_error" -> "error"
          _other -> "unknown"
        end

      %{
        "cycle" => positive_integer_or_nil(map_field(event, :cycle)),
        "status" => status,
        "summary" =>
          maybe_string(map_field(event, :summary)) ||
            maybe_string(map_field(event, :reason))
      }
    end)
    |> Enum.sort_by(fn item -> {Map.get(item, "cycle") || 0, Map.get(item, "status") || ""} end)
  end

  defp testing_cycle_summaries(_events), do: []

  defp extract_captured_prompts(events) when is_list(events) do
    events
    |> Enum.filter(fn event ->
      (Map.get(event, "type") || to_string(Map.get(event, :type))) == "prompt_captured"
    end)
    |> Enum.reduce(%{}, fn event, acc ->
      phase = to_string(Map.get(event, "phase") || Map.get(event, :phase))
      prompt = Map.get(event, "prompt") || Map.get(event, :prompt) || ""
      Map.put_new(acc, phase, prompt)
    end)
  end

  defp extract_captured_prompts(_events), do: %{}

  defp load_testing_report(metadata, files) when is_map(metadata) and is_map(files) do
    metadata_report =
      case Map.get(metadata, "testing_report") do
        report when is_map(report) -> normalize_testing_report(report)
        _other -> nil
      end

    metadata_report || read_testing_report_from_files(files)
  end

  defp load_testing_report(_metadata, _files), do: nil

  defp read_testing_report_from_files(files) when is_map(files) do
    [Map.get(files, :testing_report), Map.get(files, :testing_json)]
    |> Enum.find_value(fn path ->
      if is_binary(path) and File.exists?(path) do
        with {:ok, content} <- File.read(path),
             {:ok, decoded} <- Jason.decode(content),
             true <- is_map(decoded) do
          normalize_testing_report(decoded)
        else
          _other -> nil
        end
      else
        nil
      end
    end)
  end

  defp read_testing_report_from_files(_files), do: nil

  defp load_testing_cycle_reports(files) when is_map(files) do
    load_cycle_reports(files, :testing_cycles_dir, &normalize_testing_report/1)
  end

  defp load_testing_cycle_reports(_files), do: []

  defp load_cycle_reports(files, dir_key, normalizer)
       when is_map(files) and is_atom(dir_key) and is_function(normalizer, 1) do
    files
    |> cycle_report_paths(dir_key)
    |> Enum.map(fn path ->
      with {:ok, decoded} <- read_cycle_report_json(path),
           normalized when is_map(normalized) <- normalizer.(decoded) do
        normalized
        |> Map.put("cycle", cycle_report_number(path))
        |> Map.put("path", path)
      else
        _other -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn cycle_report ->
      {Map.get(cycle_report, "cycle") || 0, Map.get(cycle_report, "path") || ""}
    end)
  end

  defp load_cycle_reports(_files, _dir_key, _normalizer), do: []

  defp cycle_report_paths(files, dir_key) when is_map(files) and is_atom(dir_key) do
    case files |> map_field(dir_key) |> maybe_string() do
      nil ->
        []

      dir ->
        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.filter(&String.match?(&1, ~r/^cycle-\d+\.json$/))
            |> Enum.sort()
            |> Enum.map(&Path.join(dir, &1))

          {:error, _reason} ->
            []
        end
    end
  end

  defp cycle_report_paths(_files, _dir_key), do: []

  defp read_cycle_report_json(path) when is_binary(path) do
    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      _other -> {:error, :invalid_cycle_report}
    end
  end

  defp read_cycle_report_json(_path), do: {:error, :invalid_cycle_report}

  defp cycle_report_number(path) when is_binary(path) do
    case Regex.run(~r/^cycle-(\d+)\.json$/, Path.basename(path)) do
      [_, value] -> positive_integer_or_nil(value)
      _other -> nil
    end
  end

  defp cycle_report_number(_path), do: nil

  defp normalize_testing_report(report) when is_map(report) do
    verdict =
      report
      |> map_field(:verdict)
      |> maybe_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    if verdict in ["pass", "fail"] do
      checkpoints =
        report
        |> map_field(:checkpoints)
        |> normalize_testing_report_checkpoints()

      artifacts =
        report
        |> map_field(:artifacts)
        |> normalize_testing_report_artifacts()

      %{
        "verdict" => verdict,
        "summary" => maybe_string(map_field(report, :summary)),
        "checkpoints" => checkpoints,
        "artifacts" => artifacts,
        "raw" => report
      }
    else
      nil
    end
  end

  defp normalize_testing_report(_report), do: nil

  defp normalize_testing_report_checkpoints(checkpoints) when is_list(checkpoints) do
    checkpoints
    |> Enum.map(&normalize_testing_report_checkpoint/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_testing_report_checkpoints(_checkpoints), do: []

  defp normalize_testing_report_checkpoint(checkpoint) when is_map(checkpoint) do
    name = maybe_string(map_field(checkpoint, :name)) || "checkpoint"

    status =
      checkpoint
      |> map_field(:status)
      |> maybe_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    if is_nil(status) do
      nil
    else
      %{
        "name" => name,
        "status" => status,
        "details" => maybe_string(map_field(checkpoint, :details))
      }
    end
  end

  defp normalize_testing_report_checkpoint(_checkpoint), do: nil

  defp normalize_testing_report_artifacts(artifacts) when is_list(artifacts) do
    artifacts
    |> Enum.map(&normalize_testing_report_artifact/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_testing_report_artifacts(_artifacts), do: []

  defp normalize_testing_report_artifact(artifact) when is_map(artifact) do
    path = maybe_string(map_field(artifact, :path))

    if is_nil(path) do
      nil
    else
      %{
        "kind" => maybe_string(map_field(artifact, :kind)),
        "path" => path,
        "description" => maybe_string(map_field(artifact, :description)),
        "source_path" => maybe_string(map_field(artifact, :source_path)),
        "stored_path" => maybe_string(map_field(artifact, :stored_path)),
        "storage_error" => maybe_string(map_field(artifact, :storage_error))
      }
    end
  end

  defp normalize_testing_report_artifact(_artifact), do: nil

  defp workflow_fingerprint_status(snapshot, current_workflow_identity) do
    attempt_sha = snapshot |> snapshot_value(["workflow", "sha256"]) |> maybe_string()

    current_sha =
      current_workflow_identity |> map_or_empty() |> Map.get("sha256") |> maybe_string()

    cond do
      is_nil(attempt_sha) or is_nil(current_sha) -> :unknown
      attempt_sha == current_sha -> :match
      true -> :mismatch
    end
  end

  defp snapshot_workflow_fingerprint(snapshot) do
    snapshot
    |> snapshot_value(["workflow", "sha256"])
    |> to_display_text("Unavailable")
  end

  defp current_workflow_fingerprint(workflow_identity) do
    workflow_identity
    |> map_or_empty()
    |> Map.get("sha256")
    |> to_display_text("Unavailable")
  end

  defp snapshot_workflow_version(snapshot) do
    snapshot
    |> snapshot_value(["workflow", "version"])
    |> to_display_text("Not recorded")
  end

  defp snapshot_workflow_path(snapshot) do
    snapshot
    |> snapshot_value(["workflow", "path"])
    |> to_display_text("Unavailable")
  end

  defp snapshot_main_agent(snapshot) do
    snapshot
    |> snapshot_value(["resolved", "agent"])
    |> format_agent_snapshot()
  end

  defp snapshot_review_agent(snapshot) do
    snapshot
    |> snapshot_value(["resolved", "review", "agent"])
    |> format_agent_snapshot()
  end

  defp snapshot_review_cycles(snapshot) do
    snapshot
    |> snapshot_value(["resolved", "review", "max_cycles"])
    |> to_display_text("Unavailable")
  end

  defp snapshot_checks_toggle(snapshot) do
    case snapshot_value(snapshot, ["resolved", "checks", "required"]) do
      required when is_list(required) and required != [] ->
        "Enabled (#{length(required)} required)"

      required when is_list(required) ->
        "Disabled"

      _other ->
        "Unavailable"
    end
  end

  defp snapshot_review_toggle(snapshot) do
    snapshot
    |> snapshot_value(["resolved", "review", "enabled"])
    |> toggle_text()
  end

  defp snapshot_testing_toggle(snapshot) do
    enabled = snapshot_value(snapshot, ["resolved", "testing", "enabled"])

    cond do
      truthy_value?(enabled) ->
        "Enabled"

      falsey_value?(enabled) ->
        "Disabled"

      true ->
        "Unavailable"
    end
  end

  defp humanize_override_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_override_key(key), do: to_string(key)

  defp snapshot_preview_toggle(snapshot) do
    enabled = snapshot_value(snapshot, ["resolved", "preview", "enabled"])
    ttl = snapshot_value(snapshot, ["resolved", "preview", "ttl_minutes"])

    cond do
      truthy_value?(enabled) and is_integer(ttl) and ttl > 0 ->
        "Enabled (#{ttl}m TTL)"

      truthy_value?(enabled) ->
        "Enabled"

      falsey_value?(enabled) ->
        "Disabled"

      true ->
        "Unavailable"
    end
  end

  defp snapshot_publish_toggle(snapshot) do
    mode = snapshot |> snapshot_value(["resolved", "publish", "mode"]) |> maybe_string()
    provider = snapshot |> snapshot_value(["resolved", "publish", "provider"]) |> maybe_string()

    cond do
      mode && provider -> "Enabled (#{mode}, #{provider})"
      mode -> "Enabled (#{mode})"
      provider -> "Enabled (#{provider})"
      true -> "Unavailable"
    end
  end

  defp snapshot_runtime_toggle(snapshot) do
    process_count =
      case snapshot_value(snapshot, ["resolved", "runtime", "processes"]) do
        processes when is_list(processes) -> length(processes)
        _other -> 0
      end

    if process_count > 0 do
      suffix = if(process_count == 1, do: "", else: "es")
      "Enabled (pitchfork, #{process_count} process#{suffix})"
    else
      "Unavailable"
    end
  end

  defp normalize_report_cycles(cycles) when is_list(cycles) do
    cycles
    |> Enum.map(fn cycle ->
      if is_map(cycle) do
        %{
          "cycle" => positive_integer_or_nil(map_field(cycle, :cycle)),
          "status" =>
            cycle
            |> map_field(:status)
            |> maybe_string()
            |> case do
              nil -> nil
              value -> String.downcase(value)
            end,
          "summary" => maybe_string(map_field(cycle, :summary))
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_report_cycles(_cycles), do: []

  defp normalize_review_cycle_reports(cycle_reports) when is_list(cycle_reports) do
    cycle_reports
    |> Enum.map(fn cycle_report ->
      if is_map(cycle_report) do
        verdict =
          cycle_report
          |> map_field(:verdict)
          |> maybe_string()
          |> case do
            nil -> nil
            value -> String.downcase(value)
          end

        if verdict in ["pass", "fail"] do
          %{
            "cycle" => positive_integer_or_nil(map_field(cycle_report, :cycle)),
            "verdict" => verdict,
            "summary" => maybe_string(map_field(cycle_report, :summary)),
            "findings" =>
              cycle_report
              |> map_field(:findings)
              |> normalize_review_report_findings(),
            "raw" => map_field(cycle_report, :raw) || cycle_report
          }
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn cycle_report ->
      {Map.get(cycle_report, "cycle") || 0, Map.get(cycle_report, "verdict") || ""}
    end)
  end

  defp normalize_review_cycle_reports(_cycle_reports), do: []

  defp normalize_testing_cycle_reports(cycle_reports) when is_list(cycle_reports) do
    cycle_reports
    |> Enum.map(fn cycle_report ->
      if is_map(cycle_report) do
        verdict =
          cycle_report
          |> map_field(:verdict)
          |> maybe_string()
          |> case do
            nil -> nil
            value -> String.downcase(value)
          end

        if verdict in ["pass", "fail"] do
          %{
            "cycle" => positive_integer_or_nil(map_field(cycle_report, :cycle)),
            "verdict" => verdict,
            "summary" => maybe_string(map_field(cycle_report, :summary)),
            "checkpoints" =>
              cycle_report
              |> map_field(:checkpoints)
              |> normalize_testing_report_checkpoints(),
            "artifacts" =>
              cycle_report
              |> map_field(:artifacts)
              |> normalize_testing_report_artifacts(),
            "raw" => map_field(cycle_report, :raw) || cycle_report
          }
        end
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn cycle_report ->
      {Map.get(cycle_report, "cycle") || 0, Map.get(cycle_report, "verdict") || ""}
    end)
  end

  defp normalize_testing_cycle_reports(_cycle_reports), do: []

  defp review_verdict_badge_class("pass"),
    do: "badge badge-success badge-outline text-xs font-semibold"

  defp review_verdict_badge_class("fail"),
    do: "badge badge-error badge-outline text-xs font-semibold"

  defp review_verdict_badge_class(_verdict),
    do: "badge badge-ghost text-xs font-semibold"

  defp review_finding_severity_badge_class("critical"),
    do: "badge badge-error badge-outline text-xs font-semibold"

  defp review_finding_severity_badge_class("major"),
    do: "badge badge-warning badge-outline text-xs font-semibold"

  defp review_finding_severity_badge_class("minor"),
    do: "badge badge-info badge-outline text-xs font-semibold"

  defp review_finding_severity_badge_class(_severity),
    do: "badge badge-ghost text-xs font-semibold"

  defp testing_verdict_badge_class("pass"),
    do: "badge badge-success badge-outline text-xs font-semibold"

  defp testing_verdict_badge_class("fail"),
    do: "badge badge-error badge-outline text-xs font-semibold"

  defp testing_verdict_badge_class(_verdict),
    do: "badge badge-ghost text-xs font-semibold"

  defp testing_checkpoint_badge_class(status) when status in ["pass", "passed", "ok"] do
    "badge badge-success badge-outline text-xs"
  end

  defp testing_checkpoint_badge_class(status) when status in ["fail", "failed"] do
    "badge badge-error badge-outline text-xs"
  end

  defp testing_checkpoint_badge_class(status) when status in ["warning", "warn"] do
    "badge badge-warning badge-outline text-xs"
  end

  defp testing_checkpoint_badge_class(status) when status in ["skipped", "skip"] do
    "badge badge-ghost text-xs"
  end

  defp testing_checkpoint_badge_class(_status), do: "badge badge-ghost text-xs"

  defp attach_testing_artifact_preview(artifact, project_slug, story_id, attempt)
       when is_map(artifact) do
    stored_path = maybe_string(Map.get(artifact, "stored_path"))
    path = maybe_string(Map.get(artifact, "path"))
    kind = maybe_string(Map.get(artifact, "kind"))
    preview_type = testing_artifact_preview_type(kind, path, stored_path)
    stored_url = testing_artifact_route(project_slug, story_id, attempt, stored_path)

    preview_url =
      cond do
        preview_type in ["image", "video"] and is_binary(stored_url) ->
          stored_url

        preview_type in ["image", "video"] and is_binary(path) and http_url?(path) ->
          path

        true ->
          nil
      end

    artifact
    |> Map.put("stored_url", stored_url)
    |> Map.put("preview_type", preview_type)
    |> Map.put("preview_url", preview_url)
  end

  defp attach_testing_artifact_preview(artifact, _project_slug, _story_id, _attempt), do: artifact

  defp attach_testing_report_artifact_previews(report, project_slug, story_id, attempt)
       when is_map(report) do
    artifacts =
      report
      |> Map.get("artifacts", [])
      |> case do
        values when is_list(values) ->
          Enum.map(values, fn artifact ->
            attach_testing_artifact_preview(artifact, project_slug, story_id, attempt)
          end)

        _other ->
          []
      end

    Map.put(report, "artifacts", artifacts)
  end

  defp attach_testing_report_artifact_previews(report, _project_slug, _story_id, _attempt),
    do: report

  defp testing_artifact_preview_type(kind, path, stored_path) do
    normalized_kind =
      kind
      |> maybe_string()
      |> case do
        nil -> nil
        value -> String.downcase(value)
      end

    extension =
      [stored_path, path]
      |> Enum.find_value(fn item ->
        item
        |> maybe_string()
        |> case do
          nil -> nil
          value -> value |> Path.extname() |> String.downcase()
        end
      end)

    cond do
      normalized_kind in ["screenshot", "image"] -> "image"
      normalized_kind == "video" -> "video"
      extension in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg"] -> "image"
      extension in [".webm", ".mp4", ".mov", ".m4v", ".ogv"] -> "video"
      true -> nil
    end
  end

  defp testing_artifact_route(project_slug, story_id, attempt, stored_path)
       when is_binary(project_slug) and is_binary(story_id) and is_binary(stored_path) do
    case parse_attempt(attempt) do
      attempt_num when is_integer(attempt_num) and attempt_num > 0 ->
        filename = Path.basename(stored_path)

        if maybe_string(filename) do
          ~p"/projects/#{project_slug}/runs/#{story_id}/#{attempt_num}/artifacts/#{filename}"
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp testing_artifact_route(_project_slug, _story_id, _attempt, _stored_path), do: nil

  defp valid_artifact_preview?(url, type) do
    valid_artifact_preview_type?(type) and valid_artifact_preview_url?(url)
  end

  defp valid_artifact_preview_type?(type) when is_binary(type) do
    String.downcase(type) in ["image", "video"]
  end

  defp valid_artifact_preview_type?(_type), do: false

  defp valid_artifact_preview_url?(url) when is_binary(url) do
    trimmed = String.trim(url)
    trimmed != "" and (String.starts_with?(trimmed, "/") or http_url?(trimmed))
  end

  defp valid_artifact_preview_url?(_url), do: false

  defp http_url?(value) when is_binary(value) do
    String.starts_with?(value, "http://") or String.starts_with?(value, "https://")
  end

  defp http_url?(_value), do: false

  defp pretty_json(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _reason} -> nil
    end
  end

  defp pretty_json(_value), do: nil

  defp current_workflow_identity(project) do
    path = workflow_path(project)

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        %{}

      not File.exists?(path) ->
        %{"path" => path}

      true ->
        case File.read(path) do
          {:ok, content} ->
            %{"path" => path, "sha256" => sha256_hex(content)}

          {:error, _reason} ->
            %{"path" => path}
        end
    end
  end

  defp snapshot_value(snapshot, path) when is_map(snapshot) and is_list(path),
    do: get_in(snapshot, path)

  defp snapshot_value(_snapshot, _path), do: nil

  defp format_agent_snapshot(agent) when is_map(agent) do
    kind = maybe_string(Map.get(agent, "kind")) || "unknown"
    command = maybe_string(Map.get(agent, "command"))

    timeout_label =
      case Map.get(agent, "timeout_ms") do
        timeout when is_integer(timeout) -> " #{timeout}ms"
        _other -> ""
      end

    if command, do: "#{kind}#{timeout_label} (#{command})", else: "#{kind}#{timeout_label}"
  end

  defp format_agent_snapshot(_agent), do: "Unavailable"

  defp toggle_text(true), do: "Enabled"
  defp toggle_text(false), do: "Disabled"
  defp toggle_text("true"), do: "Enabled"
  defp toggle_text("false"), do: "Disabled"
  defp toggle_text(_value), do: "Unavailable"

  defp truthy_value?(true), do: true
  defp truthy_value?("true"), do: true
  defp truthy_value?(_value), do: false

  defp falsey_value?(false), do: true
  defp falsey_value?("false"), do: true
  defp falsey_value?(_value), do: false

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp maybe_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp maybe_string(value) when is_atom(value), do: value |> Atom.to_string() |> maybe_string()
  defp maybe_string(_value), do: nil

  defp to_display_text(value, _fallback) when is_integer(value), do: Integer.to_string(value)
  defp to_display_text(value, _fallback) when is_float(value), do: Float.to_string(value)

  defp to_display_text(value, _fallback) when is_boolean(value),
    do: if(value, do: "true", else: "false")

  defp to_display_text(value, fallback) when is_binary(value) do
    maybe_string(value) || fallback
  end

  defp to_display_text(value, fallback) when is_atom(value) do
    value
    |> Atom.to_string()
    |> to_display_text(fallback)
  end

  defp to_display_text(_value, fallback), do: fallback

  defp sha256_hex(payload) when is_binary(payload) do
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :lower)
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
    "testing_agent" => :tester_stdout,
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
      {:ok, content} when byte_size(content) > 0 -> normalize_log_tab_content(content, tab)
      _ -> nil
    end
  end

  defp read_log_tab_content(_files, _tab), do: nil

  defp normalize_log_tab_content(content, tab)
       when tab in ["agent", "review_agent", "testing_agent"] and is_binary(content) do
    CursorStreamLog.render(content)
  end

  defp normalize_log_tab_content(content, _tab), do: content

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
