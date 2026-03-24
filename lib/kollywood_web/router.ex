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

    get "/", PageController, :home

    # Dashboard routes with project scope
    live "/projects/:project_slug", DashboardLive, :overview
    live "/projects/:project_slug/stories", DashboardLive, :stories
    live "/projects/:project_slug/runs", DashboardLive, :runs
    live "/projects/:project_slug/settings", DashboardLive, :settings
  end

  # Other scopes may use custom stacks.
  # scope "/api", KollywoodWeb do
  #   pipe_through :api
  # end
end
