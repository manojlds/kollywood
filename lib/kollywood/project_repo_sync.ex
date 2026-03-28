defmodule Kollywood.ProjectRepoSync do
  @moduledoc """
  Syncs managed repositories for all enabled projects.

  This keeps repository synchronization centralized and avoids coupling
  orchestrator startup to a single project path.
  """

  require Logger

  alias Kollywood.Projects
  alias Kollywood.RepoSync

  @default_branch "main"

  @spec sync_enabled_projects() :: :ok | {:error, String.t()}
  def sync_enabled_projects do
    projects = Projects.list_enabled_projects()
    sync_projects(projects)
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  @spec sync_projects([map()], (String.t(), String.t() -> :ok | {:error, String.t()})) :: :ok
  def sync_projects(projects, sync_fun \\ &RepoSync.sync/2)
      when is_list(projects) and is_function(sync_fun, 2) do
    Enum.each(projects, &sync_project(&1, sync_fun))
    :ok
  end

  defp sync_project(project, sync_fun) do
    local_path = Projects.local_path(project)

    if enabled_project?(project) and non_empty_string?(local_path) do
      branch = field(project, :default_branch) || @default_branch
      slug = field(project, :slug) || "unknown"

      case sync_fun.(local_path, branch) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Managed repo sync failed slug=#{slug} branch=#{branch} path=#{local_path}: #{reason}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp enabled_project?(project) do
    case field(project, :enabled) do
      false -> false
      _other -> true
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
