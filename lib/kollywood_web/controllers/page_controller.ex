defmodule KollywoodWeb.PageController do
  use KollywoodWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
