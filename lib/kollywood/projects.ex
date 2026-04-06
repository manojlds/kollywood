defmodule Kollywood.Projects do
  @moduledoc """
  Project registry CRUD for Kollywood.
  """

  import Ecto.Query

  alias Kollywood.Projects.Project
  alias Kollywood.Repo
  alias Kollywood.ServiceConfig

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

    list_projects()
    |> Enum.find(fn project -> workflow_path(project) == expanded end)
  end

  @spec local_path(Project.t() | map()) :: String.t() | nil
  def local_path(project) when is_map(project) do
    case field(project, :slug) do
      slug when is_binary(slug) and slug != "" ->
        ServiceConfig.project_repos_path(slug)

      _other ->
        nil
    end
  end

  def local_path(_project), do: nil

  @spec workflow_path(Project.t() | map()) :: String.t() | nil
  def workflow_path(project) when is_map(project) do
    provider = field(project, :provider)

    cond do
      local_provider_value?(provider) and is_binary(repository_path(field(project, :repository))) ->
        Path.join([repository_path(field(project, :repository)), ".kollywood", "WORKFLOW.md"])

      is_binary(local_path(project)) ->
        Path.join([local_path(project), ".kollywood", "WORKFLOW.md"])

      true ->
        nil
    end
  end

  def workflow_path(_project), do: nil

  @spec tracker_path(Project.t() | map()) :: String.t() | nil
  def tracker_path(project) when is_map(project) do
    tracker_path_from_slug(field(project, :slug))
  end

  def tracker_path(_project), do: nil

  @spec onboarded?(Project.t() | map()) :: boolean()
  def onboarded?(project) when is_map(project) do
    workflow_path(project)
    |> file_exists?()
    |> Kernel.or(tracker_path(project) |> file_exists?())
  end

  def onboarded?(_project), do: false

  @spec create_project(create_attrs()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> drop_derived_paths()
      |> put_default_slug()
      |> put_default_branch()
      |> normalize_local_repository()

    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_project(Project.t(), create_attrs()) ::
          {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update_project(%Project{} = project, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> drop_derived_paths()
      |> normalize_local_repository()

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

  defp drop_derived_paths(attrs) do
    attrs
    |> Map.delete("local_path")
    |> Map.delete("workflow_path")
  end

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

  defp normalize_local_repository(attrs) do
    provider = Map.get(attrs, "provider") || Map.get(attrs, :provider)

    if local_provider_value?(provider) do
      case repository_path(Map.get(attrs, "repository") || Map.get(attrs, :repository)) do
        nil -> attrs
        path -> Map.put(attrs, "repository", path)
      end
    else
      attrs
    end
  end

  defp tracker_path_from_slug(slug) when is_binary(slug) and slug != "" do
    ServiceConfig.project_tracker_path(slug)
  end

  defp tracker_path_from_slug(_slug), do: nil

  defp file_exists?(path) when is_binary(path), do: File.exists?(path)
  defp file_exists?(_path), do: false

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp local_provider_value?(value) when value in [:local, "local"], do: true
  defp local_provider_value?(_value), do: false

  defp repository_path(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: Path.expand(trimmed)
  end

  defp repository_path(_value), do: nil
end
