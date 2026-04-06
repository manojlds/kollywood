defmodule KollywoodWeb.WorkflowSchemaController do
  use KollywoodWeb, :controller

  alias Kollywood.Config

  def show(conn, _params) do
    json(conn, %{data: Config.workflow_schema()})
  end
end
