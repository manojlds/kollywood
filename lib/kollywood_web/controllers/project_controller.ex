defmodule KollywoodWeb.ProjectController do
  use KollywoodWeb, :controller

  alias Kollywood.Projects
  alias Kollywood.Projects.Project

  def resolve(conn, params) do
    requested_path = Map.get(params, "path") || File.cwd!()

    with {:ok, cwd} <- normalize_path(requested_path),
         {:ok, project} <- resolve_project(cwd) do
      json(conn, %{data: project_payload(project)})
    else
      {:error, :invalid_path} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "path must be a non-empty string"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "no project mapped to path"})
    end
  end

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if trimmed == "" do
      {:error, :invalid_path}
    else
      {:ok, Path.expand(trimmed)}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp resolve_project(path) when is_binary(path) do
    project =
      Projects.list_projects()
      |> Enum.filter(&matches_project_path?(&1, path))
      |> Enum.max_by(&best_match_length/1, fn -> nil end)

    case project do
      nil -> {:error, :not_found}
      %Project{} = project -> {:ok, project}
    end
  end

  defp matches_project_path?(%Project{} = project, path) when is_binary(path) do
    project
    |> project_paths_for_matching()
    |> Enum.any?(fn base -> path == base or String.starts_with?(path, base <> "/") end)
  end

  defp matches_project_path?(_project, _path), do: false

  defp project_paths_for_matching(%Project{provider: :local} = project) do
    [Projects.local_path(project), project.repository]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  defp project_paths_for_matching(%Project{} = project) do
    [Projects.local_path(project)]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&Path.expand/1)
  end

  defp project_paths_for_matching(_project), do: []

  defp best_match_length(%Project{} = project) do
    project
    |> project_paths_for_matching()
    |> Enum.map(&String.length/1)
    |> Enum.max(fn -> 0 end)
  end

  defp project_payload(%Project{} = project) do
    %{
      slug: project.slug,
      name: project.name,
      provider: project.provider,
      local_path: Projects.local_path(project),
      repository: project.repository
    }
  end
end
