defmodule KollywoodWeb.RunEventsController do
  use KollywoodWeb, :controller

  alias Kollywood.Orchestrator.RunLogs
  alias Kollywood.Projects
  alias Kollywood.Projects.Project
  alias Kollywood.ServiceConfig

  def index(
        conn,
        %{
          "project_slug" => project_slug,
          "story_id" => story_id,
          "attempt" => attempt_raw
        } = params
      ) do
    with {:ok, project} <- fetch_local_project(project_slug),
         {:ok, attempt} <- parse_positive_integer_param(attempt_raw, "attempt"),
         {:ok, since} <- parse_non_negative_integer_param(Map.get(params, "since"), "since", 0),
         {:ok, limit} <- parse_optional_positive_integer_param(Map.get(params, "limit"), "limit"),
         {:ok, page} <-
           RunLogs.list_events(ServiceConfig.project_data_dir(project.slug), story_id, attempt,
             since: since,
             limit: limit
           ) do
      status =
        page
        |> Map.get(:metadata, %{})
        |> Map.get("status", "unknown")

      json(conn, %{
        data: %{
          story_id: story_id,
          attempt: attempt,
          since: since,
          next_cursor: page.next_cursor,
          status: status,
          events: page.events
        }
      })
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

  defp parse_positive_integer_param(value, field)

  defp parse_positive_integer_param(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_positive_integer_param(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _other -> {:error, "#{field} must be a positive integer"}
    end
  end

  defp parse_positive_integer_param(_value, field),
    do: {:error, "#{field} must be a positive integer"}

  defp parse_non_negative_integer_param(nil, _field, default), do: {:ok, default}

  defp parse_non_negative_integer_param(value, _field, _default)
       when is_integer(value) and value >= 0,
       do: {:ok, value}

  defp parse_non_negative_integer_param(value, field, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> {:error, "#{field} must be a non-negative integer"}
    end
  end

  defp parse_non_negative_integer_param(_value, field, _default),
    do: {:error, "#{field} must be a non-negative integer"}

  defp parse_optional_positive_integer_param(nil, _field), do: {:ok, nil}
  defp parse_optional_positive_integer_param("", _field), do: {:ok, nil}

  defp parse_optional_positive_integer_param(value, field) do
    parse_positive_integer_param(value, field)
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

          _other ->
            {:error, "project tracker path is not configured"}
        end

      %Project{} ->
        {:error, "run events API is only available for local tracker projects"}
    end
  end

  defp fetch_local_project(_project_slug), do: {:error, {:not_found, "project not found"}}
end
