defmodule KollywoodWeb.StoryController do
  use KollywoodWeb, :controller

  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.Tracker.PrdJson

  def index(conn, %{"project_slug" => project_slug}) do
    with {:ok, project} <- fetch_local_project(project_slug),
         {:ok, stories} <- PrdJson.list_stories(Projects.tracker_path(project)) do
      json(conn, %{data: Enum.map(stories, &story_payload/1)})
    else
      {:error, {:not_found, reason}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def create(conn, %{"project_slug" => project_slug} = params) do
    attrs = Map.get(params, "story", params)

    with {:ok, project} <- fetch_local_project(project_slug),
         {:ok, story} <- PrdJson.create_story(Projects.tracker_path(project), attrs) do
      conn
      |> put_status(:created)
      |> json(%{data: story_payload(story)})
    else
      {:error, {:not_found, reason}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def update(conn, %{"project_slug" => project_slug, "story_id" => story_id} = params) do
    attrs = Map.get(params, "story", params)

    with {:ok, project} <- fetch_local_project(project_slug),
         {:ok, story} <- PrdJson.update_story(Projects.tracker_path(project), story_id, attrs) do
      json(conn, %{data: story_payload(story)})
    else
      {:error, {:not_found, reason}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})

      {:error, reason} ->
        status =
          if String.contains?(reason, "not found"), do: :not_found, else: :unprocessable_entity

        conn
        |> put_status(status)
        |> json(%{error: reason})
    end
  end

  def delete(conn, %{"project_slug" => project_slug, "story_id" => story_id}) do
    with {:ok, project} <- fetch_local_project(project_slug),
         :ok <- PrdJson.delete_story(Projects.tracker_path(project), story_id) do
      send_resp(conn, :no_content, "")
    else
      {:error, {:not_found, reason}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: reason})

      {:error, reason} ->
        status =
          if String.contains?(reason, "not found"), do: :not_found, else: :unprocessable_entity

        conn
        |> put_status(status)
        |> json(%{error: reason})
    end
  end

  defp fetch_local_project(project_slug) when is_binary(project_slug) do
    case Projects.get_project_by_slug(project_slug) do
      nil ->
        {:error, {:not_found, "project not found"}}

      %Project{provider: :local} = project ->
        case Projects.tracker_path(project) do
          path when is_binary(path) ->
            if String.trim(path) != "" do
              {:ok, project}
            else
              {:error, "project tracker path is not configured"}
            end

          _other -> {:error, "project tracker path is not configured"}
        end

      %Project{} ->
        {:error, "story API is only available for local tracker projects"}
    end
  end

  defp fetch_local_project(_project_slug), do: {:error, {:not_found, "project not found"}}

  defp story_payload(story) when is_map(story) do
    story
    |> Map.put(
      "allowed_status_transitions",
      PrdJson.manual_transition_targets(Map.get(story, "status"))
    )
  end
end
