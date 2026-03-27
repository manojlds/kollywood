defmodule Kollywood.AgentPool do
  @moduledoc """
  Dynamic supervisor for per-issue run workers.

  This keeps agent execution isolated from the orchestrator process and uses
  native OTP worker actors for each issue run.
  """

  use DynamicSupervisor

  alias Kollywood.RunWorker

  @type server :: GenServer.server()

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      DynamicSupervisor.start_link(__MODULE__, :ok)
    else
      DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
    end
  end

  @spec start_run(server(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(server \\ __MODULE__, opts) when is_list(opts) do
    DynamicSupervisor.start_child(server, {RunWorker, opts})
  end

  @spec stop_run(server(), pid()) :: :ok | {:error, :not_found}
  def stop_run(server \\ __MODULE__, run_pid) when is_pid(run_pid) do
    DynamicSupervisor.terminate_child(server, run_pid)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
