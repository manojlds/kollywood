defmodule Kollywood.WorkflowStore do
  @moduledoc """
  GenServer that watches WORKFLOW.md for changes and hot-reloads the config.

  Polls the file every second by comparing {mtime, size}. On change, re-parses
  and caches the config + prompt template. If a reload fails, the previous
  "last known good" config is kept and an error is logged.

  At parse time, injects runtime context into the config that cannot come from
  the WORKFLOW.md file itself:
    - `project_provider`    — from the DB project record
    - `workspace.root`      — from ServiceConfig + project slug (unless set in YAML)
    - `workspace.source`    — the project's managed clone path (unless set in YAML)
  """

  use GenServer
  require Logger

  alias Kollywood.Projects
  alias Kollywood.ServiceConfig

  @poll_interval_ms 1_000

  defstruct [
    :path,
    :project_provider,
    :project_slug,
    :project_local_path,
    :config,
    :prompt_template,
    :file_stamp,
    :last_error
  ]

  # --- Public API ---

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    name = Keyword.get(opts, :name, __MODULE__)
    project_provider = Keyword.get(opts, :project_provider)
    project_slug = Keyword.get(opts, :project_slug)
    project_local_path = Keyword.get(opts, :project_local_path)

    GenServer.start_link(
      __MODULE__,
      {path, project_provider, project_slug, project_local_path},
      name: name
    )
  end

  @doc "Returns the current config, or nil if not yet loaded."
  @spec get_config(GenServer.server()) :: Kollywood.Config.t() | nil
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  @doc "Returns the current prompt template, or nil if not yet loaded."
  @spec get_prompt_template(GenServer.server()) :: String.t() | nil
  def get_prompt_template(server \\ __MODULE__) do
    GenServer.call(server, :get_prompt_template)
  end

  @doc "Returns the last error from a failed reload, or nil."
  @spec get_last_error(GenServer.server()) :: String.t() | nil
  def get_last_error(server \\ __MODULE__) do
    GenServer.call(server, :get_last_error)
  end

  # --- GenServer callbacks ---

  @impl true
  def init({path, project_provider, project_slug, project_local_path}) do
    {path, project_provider, project_slug, project_local_path} =
      resolve_project_context(path, project_provider, project_slug, project_local_path)

    state = %__MODULE__{
      path: path,
      project_provider: project_provider,
      project_slug: project_slug,
      project_local_path: project_local_path
    }

    case load_file(state) do
      {:ok, new_state} ->
        Logger.info("WorkflowStore loaded #{path}")
        schedule_poll()
        {:ok, new_state}

      {:error, reason} ->
        Logger.warning("WorkflowStore failed initial load of #{path}: #{reason}")
        schedule_poll()
        {:ok, %{state | last_error: reason}}
    end
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call(:get_prompt_template, _from, state) do
    {:reply, state.prompt_template, state}
  end

  def handle_call(:get_last_error, _from, state) do
    {:reply, state.last_error, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = check_and_reload(state)
    schedule_poll()
    {:noreply, new_state}
  end

  # --- Private ---

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval_ms)
  end

  defp check_and_reload(state) do
    case file_stamp(state.path) do
      {:ok, stamp} when stamp != state.file_stamp ->
        case load_file(state) do
          {:ok, new_state} ->
            Logger.info("WorkflowStore reloaded #{state.path}")
            new_state

          {:error, reason} ->
            Logger.error("WorkflowStore reload failed: #{reason}")
            %{state | last_error: reason}
        end

      {:ok, _same_stamp} ->
        state

      {:error, reason} ->
        if state.last_error != reason do
          Logger.error("WorkflowStore cannot read #{state.path}: #{reason}")
        end

        %{state | last_error: reason}
    end
  end

  defp load_file(state) do
    with {:ok, content} <- File.read(state.path),
         {:ok, stamp} <- file_stamp(state.path),
         {:ok, config, prompt_template} <- Kollywood.Config.parse(content) do
      config =
        config
        |> Map.put(:project_provider, state.project_provider)
        |> inject_workspace(state)
        |> inject_tracker(state)

      {:ok,
       %{
         state
         | config: config,
           prompt_template: prompt_template,
           file_stamp: stamp,
           last_error: nil
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{reason}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fills in tracker.project_slug from the DB project slug (unless already set in YAML).
  # This allows the prd_json tracker to resolve its path via ServiceConfig rather than
  # looking inside the managed clone, which gets reset on every sync.
  defp inject_tracker(config, state) do
    tracker = config.tracker || %{}

    if is_nil(Map.get(tracker, :project_slug)) and is_binary(state.project_slug) and
         state.project_slug != "" do
      %{config | tracker: Map.put(tracker, :project_slug, state.project_slug)}
    else
      config
    end
  end

  # Fills in workspace.root and workspace.source if not explicitly set in WORKFLOW.md.
  # root  → ServiceConfig.project_workspace_root(slug) when slug is known
  # source → project_local_path (the managed clone path)
  defp inject_workspace(config, state) do
    workspace = config.workspace || %{}

    workspace =
      if is_nil(Map.get(workspace, :root)) do
        root =
          if is_binary(state.project_slug) and state.project_slug != "" do
            ServiceConfig.project_workspace_root(state.project_slug)
          else
            ServiceConfig.workspaces_dir()
          end

        Map.put(workspace, :root, root)
      else
        workspace
      end

    workspace =
      if is_nil(Map.get(workspace, :source)) and is_binary(state.project_local_path) do
        Map.put(workspace, :source, state.project_local_path)
      else
        workspace
      end

    %{config | workspace: workspace}
  end

  defp lookup_project_by_path(path) do
    Projects.get_project_by_workflow_path(path)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp resolve_project_context(path, project_provider, project_slug, project_local_path) do
    normalized_path = if is_binary(path), do: Path.expand(path), else: path

    cond do
      is_binary(project_slug) and project_slug != "" ->
        local_path =
          if is_binary(project_local_path) and project_local_path != "" do
            Path.expand(project_local_path)
          else
            nil
          end

        {normalized_path, project_provider, project_slug, local_path}

      true ->
        case lookup_project_by_path(normalized_path) || default_project() do
          nil ->
            {normalized_path, project_provider, project_slug, project_local_path}

          project ->
            resolved_path = Projects.workflow_path(project) || normalized_path
            local_path = Projects.local_path(project)
            {resolved_path, project.provider, project.slug, local_path}
        end
    end
  end

  defp default_project do
    enabled = Projects.list_enabled_projects()

    Enum.find(enabled, fn project -> project.provider == :local end) ||
      List.first(enabled)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp file_stamp(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, {mtime, size}}
      {:error, reason} -> {:error, "#{reason}"}
    end
  end
end
