defmodule KollywoodWeb.Router do
  use KollywoodWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {KollywoodWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :internal_api do
    plug :accepts, ["json"]
    plug KollywoodWeb.Plugs.InternalApiAuth
  end

  scope "/", KollywoodWeb do
    pipe_through :browser

    live "/admin", AdminLive, :overview
    live "/admin/workers", AdminLive, :workers
    live "/admin/workers/:worker_id", AdminLive, :worker_detail
    live "/", ProjectsLive, :index
    live "/projects/new", ProjectsLive, :new
    live "/projects/:project_slug", DashboardLive, :overview
    live "/projects/:project_slug/chat", ChatLive, :index
    live "/projects/:project_slug/stories", DashboardLive, :stories
    live "/projects/:project_slug/stories/:story_id", DashboardLive, :story_detail
    live "/projects/:project_slug/runs", DashboardLive, :runs

    get "/projects/:project_slug/runs/:story_id/:attempt/artifacts/:filename",
        RunArtifactsController,
        :show

    live "/projects/:project_slug/runs/:story_id", DashboardLive, :run_detail
    live "/projects/:project_slug/runs/:story_id/:attempt", DashboardLive, :run_detail

    live "/projects/:project_slug/runs/:story_id/:attempt/step/:step_idx",
         DashboardLive,
         :step_detail

    live "/projects/:project_slug/settings", DashboardLive, :settings
  end

  scope "/api", KollywoodWeb do
    pipe_through :api

    get "/health", HealthController, :show
    get "/workflow/schema", WorkflowSchemaController, :show
    get "/projects/resolve", ProjectController, :resolve
    get "/projects/:project_slug/stories", StoryController, :index
    post "/projects/:project_slug/stories", StoryController, :create
    patch "/projects/:project_slug/stories/:story_id", StoryController, :update
    delete "/projects/:project_slug/stories/:story_id", StoryController, :delete
    get "/projects/:project_slug/runs/:story_id/:attempt/events", RunEventsController, :index
    post "/projects/:project_slug/stories/:story_id/retries", StoryController, :retry_step
  end

  scope "/api/internal", KollywoodWeb do
    pipe_through :internal_api

    post "/workers/lease-next", InternalWorkerController, :lease_next
    post "/runs/:id/start", InternalWorkerController, :start
    post "/runs/:id/heartbeat", InternalWorkerController, :heartbeat
    post "/runs/:id/events", InternalWorkerController, :events
    post "/runs/:id/complete", InternalWorkerController, :complete
    post "/runs/:id/fail", InternalWorkerController, :fail
    post "/runs/:id/cancel-ack", InternalWorkerController, :cancel_ack
  end
end
