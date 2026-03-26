defmodule Kollywood.Projects do
  @moduledoc """
  Project registry CRUD for Kollywood.
  """

  import Ecto.Query

  alias Kollywood.Projects.Project
  alias Kollywood.Repo

  @type create_attrs :: map() | keyword()

  @spec list_projects() :: [Project.t()]
  def list_projects do
    Project
    |> order_by([project], asc: project.inserted_at)
    |> Repo.all()
  end

  @spec list_enabled_projects() :: [Project.t()]
  def list_enabled_projects do
    Project
    |> where([project], project.enabled == true)
    |> order_by([project], asc: project.inserted_at)
    |> Repo.all()
  end

  @spec get_project!(pos_integer()) :: Project.t()
  def get_project!(id), do: Repo.get!(Project, id)

  @spec get_project_by_slug(String.t()) :: Project.t() | nil
  def get_project_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Project, slug: String.trim(slug))
  end

  @spec get_project_by_workflow_path(String.t()) :: Project.t() | nil
  def get_project_by_workflow_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    Repo.get_by(Project, workflow_path: expanded)
  end

  @spec create_project(create_attrs()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> put_default_slug()
      |> put_default_branch()
      |> put_managed_local_path()
      |> put_default_workflow_and_tracker_paths()

    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_project(Project.t(), create_attrs()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = project, attrs) do
    attrs = normalize_attrs(attrs)

    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @spec delete_project(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete_project(%Project{} = project), do: Repo.delete(project)

  @spec change_project(Project.t(), map()) :: Ecto.Changeset.t()
  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, normalize_attrs(attrs))
  end

  @spec slugify(String.t()) :: String.t()
  def slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "project"
      slug -> slug
    end
  end

  def slugify(_value), do: "project"

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> stringify_keys()
  defp normalize_attrs(attrs) when is_map(attrs), do: stringify_keys(attrs)
  defp normalize_attrs(_attrs), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp put_default_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "", do: attrs
  defp put_default_slug(%{slug: slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp put_default_slug(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || "project"
    Map.put(attrs, "slug", slugify(to_string(name)))
  end

  defp put_default_branch(%{"default_branch" => branch} = attrs)
       when is_binary(branch) and branch != "",
       do: attrs

  defp put_default_branch(%{default_branch: branch} = attrs)
       when is_binary(branch) and branch != "",
       do: attrs

  defp put_default_branch(attrs), do: Map.put(attrs, "default_branch", "main")

  defp put_managed_local_path(attrs) do
    slug = Map.get(attrs, "slug") || Map.get(attrs, :slug)

    if is_binary(slug) and slug != "" do
      Map.put_new(attrs, "local_path", Kollywood.ServiceConfig.project_repos_path(slug))
    else
      attrs
    end
  end

  defp put_default_workflow_and_tracker_paths(attrs) do
    local_path = Map.get(attrs, "local_path") || Map.get(attrs, :local_path)
    slug = Map.get(attrs, "slug") || Map.get(attrs, :slug)

    if is_binary(local_path) and String.trim(local_path) != "" do
      local_path = local_path |> String.trim() |> Path.expand()

      # Use the kollywood-managed tracker path only when the project is using its
      # managed clone as local_path — otherwise keep tracker inside local_path.
      tracker_path =
        if is_binary(slug) and String.trim(slug) != "" and
             local_path == Kollywood.ServiceConfig.project_repos_path(String.trim(slug)) do
          Kollywood.ServiceConfig.project_tracker_path(String.trim(slug))
        else
          Path.join(local_path, "prd.json")
        end

      attrs
      |> Map.put_new("workflow_path", Path.join(local_path, "WORKFLOW.md"))
      |> Map.put_new("tracker_path", tracker_path)
      |> Map.put("local_path", local_path)
    else
      attrs
    end
  end
end
