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

  scope "/", KollywoodWeb do
    pipe_through :browser

    live "/admin", AdminLive, :index
    live "/", ProjectsLive, :index
    live "/projects/new", ProjectsLive, :new
    live "/projects/:project_slug", DashboardLive, :overview
    live "/projects/:project_slug/stories", DashboardLive, :stories
    live "/projects/:project_slug/stories/:story_id", DashboardLive, :story_detail
    live "/projects/:project_slug/runs", DashboardLive, :runs
    live "/projects/:project_slug/runs/:story_id", DashboardLive, :run_detail
    live "/projects/:project_slug/runs/:story_id/:attempt", DashboardLive, :run_detail
    live "/projects/:project_slug/settings", DashboardLive, :settings
  end
end
