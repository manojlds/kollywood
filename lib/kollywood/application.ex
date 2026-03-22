defmodule Kollywood.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    workflow_path =
      Application.get_env(:kollywood, :workflow_path, Path.join(File.cwd!(), "WORKFLOW.md"))

    children = [
      KollywoodWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:kollywood, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kollywood.PubSub},
      {Kollywood.WorkflowStore, path: workflow_path},
      KollywoodWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kollywood.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KollywoodWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
