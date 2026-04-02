defmodule Kollywood.Runtime do
  @moduledoc """
  Behaviour and dispatch for runtime environments.

  A runtime controls *how* commands (agent turns, quality checks, service
  processes) are executed. Implementations use pitchfork for process
  management and mise for tool/environment activation.

  Available runtimes:
  - `Host` — runs pitchfork directly on the machine
  - `Docker` — runs pitchfork inside a container (Ubuntu + mise + pitchfork)
  """

  alias Kollywood.Runtime.{Docker, Host}

  @type kind :: :host | :docker

  @type state :: map()

  @callback init(config :: map(), workspace :: map()) :: state()

  @callback start(state()) ::
              {:ok, state()} | {:error, String.t(), state()}

  @callback stop(state()) ::
              {:ok, state()} | {:error, String.t(), state()}

  @callback healthcheck(state()) :: :ok | {:error, String.t()}

  @callback ensure_exec_ready(state()) ::
              {:ok, state()} | {:error, String.t(), state()}

  @callback exec(state(), command :: String.t(), timeout_ms :: pos_integer()) ::
              {:ok, String.t(), non_neg_integer()}
              | {:error, String.t(), String.t(), non_neg_integer()}

  @callback wrap_agent_command(state(), command :: String.t(), args :: [String.t()]) ::
              {String.t(), [String.t()], env :: map()}

  @callback release(state()) :: state()

  @callback reclaim_workspace(state()) :: :ok | {:error, String.t()}

  @doc "Returns the implementation module for a runtime kind."
  @spec module_for(kind()) :: module()
  def module_for(:host), do: Host
  def module_for(:docker), do: Docker

  @doc "Builds initial runtime state from parsed config + workspace."
  @spec init(kind(), map(), map()) :: state()
  def init(kind, config, workspace) do
    mod = module_for(kind)
    state = mod.init(config, workspace)
    Map.put(state, :module, mod)
  end

  @doc "Builds a default runtime state (before workspace is known)."
  @spec default_state(kind(), map()) :: state()
  def default_state(kind, config) do
    mod = module_for(kind)
    state = mod.init(config, nil)
    Map.put(state, :module, mod)
  end

  @doc "Starts runtime processes (e.g. pitchfork start)."
  @spec start(state()) :: {:ok, state()} | {:error, String.t(), state()}
  def start(%{module: mod} = state), do: mod.start(state)

  @doc "Stops runtime processes."
  @spec stop(state()) :: {:ok, state()} | {:error, String.t(), state()}
  def stop(%{module: mod} = state), do: mod.stop(state)

  @doc "Performs runtime readiness checks before testing."
  @spec healthcheck(state()) :: :ok | {:error, String.t()}
  def healthcheck(%{module: mod} = state), do: mod.healthcheck(state)

  @doc "Ensures the runtime can execute commands (e.g. starts container for Docker)."
  @spec ensure_exec_ready(state()) :: {:ok, state()} | {:error, String.t(), state()}
  def ensure_exec_ready(%{module: mod} = state), do: mod.ensure_exec_ready(state)

  @doc "Executes a shell command in the runtime environment."
  @spec exec(state(), String.t(), pos_integer()) ::
          {:ok, String.t(), non_neg_integer()}
          | {:error, String.t(), String.t(), non_neg_integer()}
  def exec(%{module: mod} = state, command, timeout_ms), do: mod.exec(state, command, timeout_ms)

  @doc "Wraps an agent command for execution in this runtime."
  @spec wrap_agent_command(state(), String.t(), [String.t()]) ::
          {String.t(), [String.t()], map()}
  def wrap_agent_command(%{module: mod} = state, command, args),
    do: mod.wrap_agent_command(state, command, args)

  @doc "Releases any resources (port offset leases, etc.)."
  @spec release(state()) :: state()
  def release(%{module: mod} = state), do: mod.release(state)

  @doc "Reclaims workspace file ownership to the host user (relevant for Docker runtimes)."
  @spec reclaim_workspace(state()) :: :ok | {:error, String.t()}
  def reclaim_workspace(%{module: mod} = state), do: mod.reclaim_workspace(state)
end
