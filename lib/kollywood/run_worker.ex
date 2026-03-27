defmodule Kollywood.RunWorker do
  @moduledoc """
  Single-run worker actor.

  Executes one runner invocation and reports the result back to the orchestrator.
  """

  use GenServer

  @type run_fun :: (-> term())

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    orchestrator = Keyword.fetch!(opts, :orchestrator)
    issue_id = Keyword.fetch!(opts, :issue_id)
    run_fun = Keyword.fetch!(opts, :run_fun)

    state = %{orchestrator: orchestrator, issue_id: issue_id, run_fun: run_fun}

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    result = state.run_fun.()
    send(state.orchestrator, {:run_worker_result, state.issue_id, self(), result})
    {:stop, :normal, state}
  end
end
