defmodule Kollywood.Workspace do
  @moduledoc """
  Manages per-issue isolated workspace directories.

  Supports two strategies:

  - `clone` — creates a directory and runs hooks (default). Use `after_create` hook for git clone, deps install, etc.
  - `worktree` — git worktrees from a source repo (shared object store, instant creation)

  ## Lifecycle hooks

  - `after_create` — runs once when a new workspace is created (fatal on failure)
  - `before_run` — runs before each agent turn (fatal on failure)
  - `after_run` — runs after each attempt (failure ignored)
  - `before_remove` — runs before workspace deletion (failure ignored)
  """

  require Logger

  @type t :: %__MODULE__{
          path: String.t(),
          key: String.t(),
          root: String.t(),
          strategy: atom(),
          branch: String.t() | nil,
          source: String.t() | nil
        }

  @empty_hooks %{after_create: nil, before_run: nil, after_run: nil, before_remove: nil}

  defstruct [:path, :key, :root, :strategy, :branch, :source]

  @doc """
  Creates or reuses a workspace for the given issue identifier.
  """
  @spec create_for_issue(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def create_for_issue(identifier, config) do
    workspace_config = Map.get(config, :workspace, %{})

    root =
      expand_root(Map.get(workspace_config, :root) || Kollywood.ServiceConfig.workspaces_dir())

    key = sanitize_key(identifier)
    path = Path.join(root, key)
    strategy = Map.get(workspace_config, :strategy, :directory)
    source = source_from_workspace_config(workspace_config)

    with :ok <- validate_path(path, root),
         :ok <- File.mkdir_p(root) do
      workspace = %__MODULE__{
        path: path,
        key: key,
        root: root,
        strategy: strategy,
        source: source
      }

      if File.dir?(path) do
        Logger.info("Reusing workspace for #{identifier} at #{path}")
        {:ok, maybe_set_branch(workspace, config)}
      else
        create_new(workspace, identifier, config)
      end
    end
  end

  @doc """
  Removes the workspace for an issue identifier without creating it first.

  This is resilient to stale worktree metadata where the workspace directory may
  already be missing from disk.
  """
  @spec cleanup_for_issue(String.t(), map(), map()) :: :ok | {:error, String.t()}
  def cleanup_for_issue(identifier, config, hooks \\ %{})
      when is_binary(identifier) and is_map(config) do
    workspace_config = Map.get(config, :workspace, %{})

    root =
      expand_root(Map.get(workspace_config, :root) || Kollywood.ServiceConfig.workspaces_dir())

    key = sanitize_key(identifier)
    path = Path.join(root, key)
    strategy = Map.get(workspace_config, :strategy, :directory)
    branch_prefix = Map.get(workspace_config, :branch_prefix, "kollywood/")
    source = source_from_workspace_config(workspace_config)

    workspace = %__MODULE__{
      path: path,
      key: key,
      root: root,
      strategy: strategy,
      branch: if(strategy == :worktree, do: "#{branch_prefix}#{key}", else: nil),
      source: source
    }

    with :ok <- validate_path(path, root) do
      remove(workspace, normalize_hooks(hooks))
    end
  end

  @doc """
  Runs the `before_run` hook in the workspace directory.
  Optionally accepts a runtime state to reclaim workspace ownership first (for Docker runtimes).
  """
  @spec before_run(t(), map(), map() | nil) :: :ok | {:error, String.t()}
  def before_run(%__MODULE__{} = workspace, hooks, runtime \\ nil) do
    if runtime, do: Kollywood.Runtime.reclaim_workspace(runtime)
    run_hook(hooks.before_run, workspace.path, "before_run")
  end

  @doc """
  Runs the `after_run` hook. Failures are logged but ignored.
  """
  @spec after_run(t(), map()) :: :ok
  def after_run(%__MODULE__{} = workspace, hooks) do
    case run_hook(hooks.after_run, workspace.path, "after_run") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("after_run hook failed (ignored): #{reason}")
        :ok
    end
  end

  @doc """
  Removes the workspace. For worktrees, uses `git worktree remove`.
  """
  @spec remove(t(), map()) :: :ok
  def remove(%__MODULE__{} = workspace, hooks) do
    hooks = normalize_hooks(hooks)

    case run_hook(hooks.before_remove, workspace.path, "before_remove") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("before_remove hook failed (ignored): #{reason}")
        :ok
    end

    do_remove(workspace)
  end

  @doc """
  Returns the number of commits on this workspace's branch that are not in the source repo HEAD.
  Only meaningful for the `:worktree` strategy — returns `{:ok, :not_applicable}` otherwise.
  """
  @spec commits_ahead(t()) :: {:ok, non_neg_integer() | :not_applicable} | {:error, String.t()}
  def commits_ahead(%__MODULE__{strategy: :worktree} = workspace) do
    with {:ok, source} <- source_repo(workspace),
         {sha, 0} <- git(["rev-parse", "HEAD"], source),
         {count_str, 0} <-
           git(["rev-list", "--count", "#{String.trim(sha)}..HEAD"], workspace.path) do
      {:ok, String.trim(count_str) |> String.to_integer()}
    else
      {:error, reason} -> {:error, reason}
      {output, _code} -> {:error, "git error: #{String.trim(output)}"}
    end
  end

  def commits_ahead(%__MODULE__{}), do: {:ok, :not_applicable}

  @doc """
  Pushes the workspace branch to origin. Only applicable for the `:worktree` strategy.
  """
  @spec push_branch(t()) :: :ok | {:error, String.t()}
  def push_branch(%__MODULE__{strategy: :worktree, branch: branch} = workspace)
      when is_binary(branch) do
    case git(["push", "-u", "origin", branch], workspace.path) do
      {_output, 0} ->
        Logger.info("Pushed branch #{branch} to origin")
        :ok

      {output, code} ->
        {:error, "git push exited #{code}: #{String.trim(output)}"}
    end
  end

  def push_branch(%__MODULE__{}), do: {:error, "push_branch only supported for worktree strategy"}

  @doc """
  Merges the workspace branch into `base_branch`.

  Default path merges in the source repo and pushes to origin.
  For local non-bare origins with `base_branch` checked out, merges directly in the origin
  repository (stashing and restoring local changes) to avoid `denyCurrentBranch` push rejection.
  Only applicable for the `:worktree` strategy.
  """
  @spec merge_branch_to_main(t(), String.t()) :: :ok | {:error, String.t()}
  def merge_branch_to_main(
        %__MODULE__{strategy: :worktree, branch: branch} = workspace,
        base_branch
      )
      when is_binary(branch) and is_binary(base_branch) do
    base_branch = String.trim(base_branch)

    with {:ok, source} <- source_repo(workspace),
         :ok <- merge_branch_into_base(source, branch, base_branch) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {output, code} -> {:error, "merge to main failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  def merge_branch_to_main(%__MODULE__{}, _base_branch),
    do: {:error, "merge_branch_to_main only supported for worktree strategy"}

  @doc """
  Sanitizes an issue identifier to a safe directory name.
  Only allows `[A-Za-z0-9._-]`, replaces everything else with `_`.
  """
  @spec sanitize_key(String.t()) :: String.t()
  def sanitize_key(identifier) do
    String.replace(identifier, ~r/[^A-Za-z0-9._-]/, "_")
  end

  # --- Private: creation strategies ---

  defp create_new(workspace, identifier, config) do
    case workspace.strategy do
      :worktree -> create_worktree(workspace, identifier, config)
      _ -> create_clone(workspace, identifier, config.hooks)
    end
  end

  defp create_clone(workspace, identifier, hooks) do
    Logger.info("Creating clone workspace for #{identifier} at #{workspace.path}")

    with :ok <- File.mkdir_p(workspace.path),
         :ok <- run_hook(hooks.after_create, workspace.path, "after_create") do
      {:ok, workspace}
    else
      {:error, reason} ->
        File.rm_rf(workspace.path)
        {:error, "Failed to create workspace: #{reason}"}
    end
  end

  defp create_worktree(workspace, identifier, config) do
    workspace_config = Map.get(config, :workspace, %{})
    source = expand_root(Map.get(workspace_config, :source) || ".")
    prefix = Map.get(workspace_config, :branch_prefix, "kollywood/")
    branch = "#{prefix}#{workspace.key}"
    workspace = %{workspace | source: source}

    Logger.info("Creating worktree for #{identifier} at #{workspace.path} (branch: #{branch})")

    git(["worktree", "prune"], source)
    cleanup_stale_branch(source, branch)

    case git(["worktree", "add", "-b", branch, workspace.path], source) do
      {_output, 0} ->
        workspace = %{workspace | branch: branch}

        case run_hook(config.hooks.after_create, workspace.path, "after_create") do
          :ok ->
            {:ok, workspace}

          {:error, reason} ->
            git(["worktree", "remove", "--force", workspace.path], source)
            git(["branch", "-D", branch], source)
            {:error, "after_create hook failed: #{reason}"}
        end

      {output, _code} ->
        cond do
          File.dir?(workspace.path) ->
            Logger.info("Worktree creation raced but directory exists; reusing #{workspace.path}")

            {:ok, %{workspace | branch: branch}}

          branch_exists?(source, branch) ->
            case git(["worktree", "add", workspace.path, branch], source) do
              {_output, 0} ->
                {:ok, %{workspace | branch: branch}}

              {_, _} ->
                {:error, "Failed to create worktree: #{String.trim(output)}"}
            end

          true ->
            {:error, "Failed to create worktree: #{String.trim(output)}"}
        end
    end
  end

  # --- Private: removal ---

  defp do_remove(%__MODULE__{strategy: :worktree} = workspace) do
    case resolve_source_repo_for_cleanup(workspace) do
      {:ok, source} ->
        _ = maybe_remove_worktree_path(source, workspace.path)
        _ = maybe_prune_worktrees(source)
        _ = maybe_delete_worktree_branch(source, workspace.branch)
        _ = ensure_workspace_path_removed(workspace.path)
        :ok

      :error ->
        _ = ensure_workspace_path_removed(workspace.path)
        :ok
    end
  end

  defp do_remove(workspace) do
    case File.rm_rf(workspace.path) do
      {:ok, _} ->
        Logger.info("Removed workspace at #{workspace.path}")
        :ok

      {:error, reason, path} ->
        Logger.error("Failed to remove workspace at #{path}: #{reason}")
        :ok
    end
  end

  # --- Private: helpers ---

  defp maybe_set_branch(workspace, config) do
    workspace_config = Map.get(config, :workspace, %{})

    case workspace.strategy do
      :worktree ->
        prefix = Map.get(workspace_config, :branch_prefix, "kollywood/")
        %{workspace | branch: "#{prefix}#{workspace.key}"}

      _ ->
        workspace
    end
  end

  defp source_from_workspace_config(workspace_config) when is_map(workspace_config) do
    case Map.get(workspace_config, :source) do
      source when is_binary(source) and source != "" -> expand_root(source)
      _other -> nil
    end
  end

  defp source_from_workspace_config(_workspace_config), do: nil

  defp normalize_hooks(hooks) when is_map(hooks), do: Map.merge(@empty_hooks, hooks)
  defp normalize_hooks(_hooks), do: @empty_hooks

  defp resolve_source_repo_for_cleanup(%__MODULE__{source: source})
       when is_binary(source) and source != "" do
    expanded = expand_root(source)

    if git_repo_dir?(expanded) do
      {:ok, expanded}
    else
      :error
    end
  end

  defp resolve_source_repo_for_cleanup(workspace) do
    case source_from_worktree_git_file(workspace.path) do
      {:ok, source} ->
        if git_repo_dir?(source) do
          {:ok, source}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp source_from_worktree_git_file(path) when is_binary(path) do
    git_file = Path.join(path, ".git")

    case File.read(git_file) do
      {:ok, content} ->
        source =
          content
          |> String.trim()
          |> String.replace_prefix("gitdir: ", "")
          |> Path.dirname()
          |> Path.dirname()
          |> Path.dirname()

        {:ok, source}

      _other ->
        :error
    end
  end

  defp source_from_worktree_git_file(_path), do: :error

  defp maybe_remove_worktree_path(source, workspace_path) do
    case git(["worktree", "remove", "--force", workspace_path], source) do
      {_output, 0} ->
        Logger.info("Removed worktree at #{workspace_path}")
        :ok

      {output, _code} ->
        Logger.debug(
          "worktree remove returned non-zero for #{workspace_path} (continuing): #{String.trim(output)}"
        )

        :ok
    end
  end

  defp maybe_prune_worktrees(source) do
    case git(["worktree", "prune"], source) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        Logger.debug("worktree prune returned non-zero in #{source}: #{String.trim(output)}")
        :ok
    end
  end

  defp maybe_delete_worktree_branch(_source, branch) when branch in [nil, ""], do: :ok

  defp maybe_delete_worktree_branch(source, branch) when is_binary(branch) do
    case git(["branch", "-D", branch], source) do
      {_output, 0} ->
        Logger.info("Deleted worktree branch #{branch}")
        :ok

      {output, _code} ->
        Logger.debug(
          "branch cleanup returned non-zero for #{branch} in #{source} (continuing): #{String.trim(output)}"
        )

        :ok
    end
  end

  defp ensure_workspace_path_removed(workspace_path) do
    if File.exists?(workspace_path) do
      case File.rm_rf(workspace_path) do
        {:ok, _entries} ->
          Logger.info("Removed workspace path at #{workspace_path}")
          :ok

        {:error, reason, path} ->
          Logger.error("Failed to remove workspace path at #{path}: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp cleanup_stale_branch(source, branch) do
    case git(["show-ref", "--verify", "refs/heads/#{branch}"], source) do
      {_output, 0} ->
        Logger.info("Removing stale branch #{branch} before worktree creation")
        git(["branch", "-D", branch], source)

      _ ->
        :ok
    end
  end

  defp branch_exists?(source, branch) do
    match?({_output, 0}, git(["show-ref", "--verify", "refs/heads/#{branch}"], source))
  end

  defp git_repo_dir?(path) when is_binary(path) do
    File.dir?(path) and File.exists?(Path.join(path, ".git"))
  end

  defp git_repo_dir?(_path), do: false

  defp expand_root(root) do
    root
    |> String.replace("~", System.user_home!())
    |> Path.expand()
  end

  defp validate_path(path, root) do
    canonical_path = Path.expand(path)
    canonical_root = Path.expand(root)

    if String.starts_with?(canonical_path, canonical_root <> "/") do
      :ok
    else
      {:error, "Workspace path #{path} is outside root #{root} (path traversal blocked)"}
    end
  end

  defp merge_branch_into_base(source, branch, base_branch) do
    case resolve_checked_out_origin(source, base_branch) do
      {:ok, origin_repo} ->
        merge_in_origin_repo(origin_repo, branch, base_branch)

      :error ->
        merge_in_source_repo(source, branch, base_branch)
    end
  end

  defp merge_in_source_repo(source, branch, base_branch) do
    with {_, 0} <- git(["checkout", base_branch], source),
         {_, 0} <- git(["merge", "--no-ff", branch, "-m", "Merge branch '#{branch}'"], source),
         {_, 0} <- git(["push", "origin", base_branch], source) do
      :ok
    else
      {output, code} ->
        _ = maybe_abort_merge(source)
        {:error, "merge to main failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp merge_in_origin_repo(origin_repo, branch, base_branch) do
    stashed? = stash_local_changes?(origin_repo, branch)

    with {_, 0} <- git(["checkout", base_branch], origin_repo),
         {_, 0} <-
           git(["merge", "--no-ff", branch, "-m", "Merge branch '#{branch}'"], origin_repo),
         :ok <- maybe_restore_stash(origin_repo, stashed?) do
      :ok
    else
      {output, code} ->
        _ = maybe_abort_merge(origin_repo)
        _ = maybe_restore_stash(origin_repo, stashed?)
        {:error, "merge to main failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp resolve_checked_out_origin(source, base_branch) do
    with {:ok, origin_repo} <- resolve_local_origin_repo(source),
         true <- File.dir?(origin_repo),
         false <- bare_repo?(origin_repo),
         {:ok, current_branch} <- current_branch(origin_repo),
         true <- current_branch == base_branch do
      {:ok, origin_repo}
    else
      _ -> :error
    end
  end

  defp resolve_local_origin_repo(source) do
    case git(["config", "--get", "remote.origin.url"], source) do
      {url, 0} ->
        parse_local_origin_repo(String.trim(url), source)

      {_output, _code} ->
        {:error, "could not resolve origin for #{source}"}
    end
  end

  defp parse_local_origin_repo("", _source), do: {:error, "origin URL is empty"}

  defp parse_local_origin_repo("file://" <> rest, _source) do
    {:ok, Path.expand(URI.decode(rest))}
  end

  defp parse_local_origin_repo(url, source) do
    if local_origin_path?(url) do
      {:ok, Path.expand(url, source)}
    else
      {:error, "origin is not a local repository path"}
    end
  end

  defp local_origin_path?(url) when is_binary(url) do
    not String.contains?(url, "://") and
      not Regex.match?(~r/^[^\/]+@[^:]+:.+$/, url)
  end

  defp bare_repo?(repo) do
    case git(["rev-parse", "--is-bare-repository"], repo) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp current_branch(repo) do
    case git(["rev-parse", "--abbrev-ref", "HEAD"], repo) do
      {branch, 0} ->
        {:ok, String.trim(branch)}

      {output, code} ->
        {:error, "failed to read current branch (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp stash_local_changes?(repo, branch) do
    case git(["status", "--porcelain"], repo) do
      {"", 0} ->
        false

      {changes, 0} when is_binary(changes) ->
        case git(
               ["stash", "push", "--include-untracked", "-m", "kollywood auto-merge #{branch}"],
               repo
             ) do
          {_output, 0} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp maybe_restore_stash(_repo, false), do: :ok

  defp maybe_restore_stash(repo, true) do
    case git(["stash", "pop"], repo) do
      {_output, 0} ->
        :ok

      {output, _code} ->
        Logger.warning(
          "Merged main but could not restore stashed changes in #{repo}; run `git stash list` and resolve manually: #{String.trim(output)}"
        )

        :ok
    end
  end

  defp maybe_abort_merge(repo) do
    _ = git(["merge", "--abort"], repo)
    :ok
  end

  defp run_hook(nil, _cwd, _name), do: :ok
  defp run_hook("", _cwd, _name), do: :ok

  defp run_hook(script, cwd, name) do
    Logger.debug("Running #{name} hook in #{cwd}")

    case System.cmd("bash", ["-c", script], cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, exit_code} ->
        {:error, "#{name} hook exited with code #{exit_code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "#{name} hook failed: #{Exception.message(e)}"}
  end

  defp source_repo(%__MODULE__{strategy: :worktree, source: source} = workspace)
       when is_binary(source) and source != "" do
    expanded = expand_root(source)

    if git_repo_dir?(expanded) do
      {:ok, expanded}
    else
      source_repo(%{workspace | source: nil})
    end
  end

  defp source_repo(%__MODULE__{strategy: :worktree} = workspace) do
    case source_from_worktree_git_file(workspace.path) do
      {:ok, source} ->
        {:ok, source}

      :error ->
        {:error, "could not read worktree .git file"}
    end
  end

  defp git(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
