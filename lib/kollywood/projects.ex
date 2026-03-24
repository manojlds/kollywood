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

  @spec create_project(create_attrs()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create_project(attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> put_default_slug()
      |> put_default_branch()
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

  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(_attrs), do: %{}

  defp put_default_slug(%{"slug" => slug} = attrs) when is_binary(slug) and slug != "", do: attrs
  defp put_default_slug(%{slug: slug} = attrs) when is_binary(slug) and slug != "", do: attrs

  defp put_default_slug(attrs) do
    name = Map.get(attrs, :name) || Map.get(attrs, "name") || "project"
    Map.put(attrs, :slug, slugify(to_string(name)))
  end

  defp put_default_branch(%{"default_branch" => branch} = attrs)
       when is_binary(branch) and branch != "",
       do: attrs

  defp put_default_branch(%{default_branch: branch} = attrs)
       when is_binary(branch) and branch != "",
       do: attrs

  defp put_default_branch(attrs), do: Map.put(attrs, :default_branch, "main")

  defp put_default_workflow_and_tracker_paths(attrs) do
    provider = Map.get(attrs, :provider) || Map.get(attrs, "provider")
    local_path = Map.get(attrs, :local_path) || Map.get(attrs, "local_path")

    if provider in [:local, "local"] and is_binary(local_path) and String.trim(local_path) != "" do
      local_path = Path.expand(String.trim(local_path))

      attrs
      |> Map.put_new(:workflow_path, Path.join(local_path, "WORKFLOW.md"))
      |> Map.put_new(:tracker_path, Path.join(local_path, "prd.json"))
      |> Map.put(:local_path, local_path)
    else
      attrs
    end
  end
end
