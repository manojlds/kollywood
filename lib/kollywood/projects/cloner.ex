defmodule Kollywood.Projects.Cloner do
  @moduledoc """
  Clones a remote repository to a local path for GitHub and GitLab projects.

  Tries the platform CLI first (gh / glab) since they handle auth automatically.
  Falls back to plain `git clone` if the CLI is not available.
  """

  require Logger

  @doc """
  Clones `repository` (e.g. `"owner/repo"`) for `provider` into `local_path`.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec clone(atom(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def clone(provider, repository, local_path) do
    with :ok <- File.mkdir_p(Path.dirname(local_path)) do
      Logger.info("Cloning #{provider} repo #{repository} → #{local_path}")
      do_clone(provider, repository, local_path)
    else
      {:error, reason} -> {:error, "could not create parent directory: #{inspect(reason)}"}
    end
  end

  defp do_clone(:github, repo, path) do
    case System.cmd("gh", ["repo", "clone", repo, path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning("gh repo clone failed (#{code}): #{output}; trying git clone")
        git_clone("https://github.com/#{repo}.git", path)
    end
  rescue
    _ -> git_clone("https://github.com/#{repo}.git", path)
  end

  defp do_clone(:gitlab, repo, path) do
    case System.cmd("glab", ["repo", "clone", repo, path], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning("glab repo clone failed (#{code}): #{output}; trying git clone")
        git_clone("https://gitlab.com/#{repo}.git", path)
    end
  rescue
    _ -> git_clone("https://gitlab.com/#{repo}.git", path)
  end

  defp git_clone(url, path) do
    case System.cmd("git", ["clone", url, path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, code} -> {:error, "git clone exited #{code}: #{String.trim(output)}"}
    end
  end

  @doc """
  Returns the suggested default local path for a repository.
  E.g. `"owner/my-repo"` → `"~/kollywood-repos/my-repo"`.
  """
  @spec default_path(String.t()) :: String.t()
  def default_path(repository) when is_binary(repository) do
    repo_name =
      repository
      |> String.split("/")
      |> List.last()
      |> String.replace(~r/\.git$/, "")
      |> String.trim()

    name = if repo_name == "", do: "repo", else: repo_name
    "~/kollywood-repos/#{name}"
  end

  def default_path(_), do: "~/kollywood-repos/repo"
end
