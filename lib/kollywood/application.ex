defmodule Kollywood.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Kollywood.AppMode
  alias Kollywood.ServiceConfig

  @impl true
  def start(_type, _args) do
    app_mode = AppMode.normalize(Application.get_env(:kollywood, :app_mode, :all))

    workflow_path =
      Application.get_env(:kollywood, :workflow_path, ServiceConfig.default_workflow_path())

    workflow_store_opts = [path: workflow_path]

    children =
      app_mode
      |> children_for_mode(workflow_store_opts)
      |> maybe_add_orchestrator(app_mode)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kollywood.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp children_for_mode(mode, workflow_store_opts) do
    shared_children = [
      KollywoodWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:kollywood, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kollywood.PubSub}
    ]

    children =
      if AppMode.data_enabled?(mode) do
        [Kollywood.Repo, Kollywood.Store.Bootstrap | shared_children]
      else
        shared_children
      end

    children =
      if AppMode.agent_pool_enabled?(mode) do
        children ++ [{Kollywood.AgentPool, name: Kollywood.AgentPool}]
      else
        children
      end

    children =
      if AppMode.data_enabled?(mode) do
        children ++
          [{Kollywood.WorkflowStore, workflow_store_opts}, {Kollywood.PrdJsonArchiver, []}]
      else
        children
      end

    children =
      if AppMode.worker_consumer_enabled?(mode) and
           Application.get_env(:kollywood, :worker_consumer_enabled, true) do
        worker_count =
          Application.get_env(:kollywood, :worker_consumer_count, 1)

        worker_concurrency =
          Application.get_env(:kollywood, :worker_consumer_concurrency, 1)

        worker_children =
          for i <- 1..worker_count do
            name = :"Kollywood.WorkerConsumer.#{i}"

            {Kollywood.WorkerConsumer,
             name: name, max_local_workers: worker_concurrency, worker_id: i}
          end

        children ++ worker_children
      else
        children
      end

    children =
      if AppMode.web_enabled?(mode),
        do: children ++ [Kollywood.PreviewSessionManager, KollywoodWeb.Endpoint],
        else: children ++ [Kollywood.PreviewSessionManager]

    children
  end

  defp maybe_add_orchestrator(children, mode) do
    if AppMode.orchestrator_enabled?(mode) and
         Application.get_env(:kollywood, :orchestrator_enabled, true) do
      orchestrator_opts =
        case Application.get_env(:kollywood, :orchestrator, []) do
          opts when is_list(opts) -> opts
          _other -> []
        end

      dispatch_mode =
        Application.get_env(:kollywood, :orchestrator_dispatch_mode, :local)

      child_opts =
        orchestrator_opts
        |> Keyword.put_new(:workflow_store, Kollywood.WorkflowStore)
        |> Keyword.put_new(:agent_pool, Kollywood.AgentPool)
        |> Keyword.put_new(:repo_syncer, Kollywood.ProjectRepoSync)
        |> Keyword.put_new(:dispatch_mode, dispatch_mode)

      children ++ [{Kollywood.Orchestrator, child_opts}]
    else
      children
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KollywoodWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
