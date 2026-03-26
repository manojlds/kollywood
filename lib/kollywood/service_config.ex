defmodule Kollywood.ServiceConfig do
  @moduledoc """
  Kollywood service-level configuration.

  Resolves the Kollywood home directory from (in priority order):
    1. `KOLLYWOOD_HOME` environment variable
    2. `~/.kollywood` (default)

  Directory layout under home:
    repos/        — Kollywood-managed source clones (one per project)
    workspaces/   — Per-issue agent workspaces (subdirectory per project slug)
  """

  @default_home "~/.kollywood"

  @doc "Returns the resolved Kollywood home directory path."
  @spec kollywood_home() :: String.t()
  def kollywood_home do
    (System.get_env("KOLLYWOOD_HOME") || @default_home)
    |> Path.expand()
  end

  @doc "Directory where Kollywood-managed source clones live."
  @spec repos_dir() :: String.t()
  def repos_dir, do: Path.join(kollywood_home(), "repos")

  @doc "Directory where per-issue agent workspaces live."
  @spec workspaces_dir() :: String.t()
  def workspaces_dir, do: Path.join(kollywood_home(), "workspaces")

  @doc "Workspace root for a specific project (workspaces/<slug>/)."
  @spec project_workspace_root(String.t()) :: String.t()
  def project_workspace_root(slug) when is_binary(slug) and slug != "" do
    Path.join(workspaces_dir(), slug)
  end

  @doc "Managed clone path for a specific project (repos/<slug>/)."
  @spec project_repos_path(String.t()) :: String.t()
  def project_repos_path(slug) when is_binary(slug) and slug != "" do
    Path.join(repos_dir(), slug)
  end

  @doc "Tracker file path for a specific project (projects/<slug>/prd.json)."
  @spec project_tracker_path(String.t()) :: String.t()
  def project_tracker_path(slug) when is_binary(slug) and slug != "" do
    Path.join([kollywood_home(), "projects", slug, "prd.json"])
  end
end
