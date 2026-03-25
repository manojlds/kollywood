defmodule Kollywood.WorkflowStore do
  @moduledoc """
  GenServer that watches WORKFLOW.md for changes and hot-reloads the config.

  Polls the file every second by comparing {mtime, size}. On change, re-parses
  and caches the config + prompt template. If a reload fails, the previous
  "last known good" config is kept and an error is logged.
  """

  use GenServer
  require Logger

  @poll_interval_ms 1_000

  defstruct [:path, :project_provider, :config, :prompt_template, :file_stamp, :last_error]

  # --- Public API ---

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    name = Keyword.get(opts, :name, __MODULE__)
    project_provider = Keyword.get(opts, :project_provider)
    GenServer.start_link(__MODULE__, {path, project_provider}, name: name)
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
  def init({path, project_provider}) do
    state = %__MODULE__{path: path, project_provider: project_provider}

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
      config = %{config | project_provider: state.project_provider}

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

  defp file_stamp(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime, size: size}} -> {:ok, {mtime, size}}
      {:error, reason} -> {:error, "#{reason}"}
    end
  end
end
