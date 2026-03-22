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
          branch: String.t() | nil
        }

  defstruct [:path, :key, :root, :strategy, :branch]

  @doc """
  Creates or reuses a workspace for the given issue identifier.
  """
  @spec create_for_issue(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def create_for_issue(identifier, config) do
    root = expand_root(config.workspace.root)
    key = sanitize_key(identifier)
    path = Path.join(root, key)
    strategy = Map.get(config.workspace, :strategy, :directory)

    with :ok <- validate_path(path, root),
         :ok <- File.mkdir_p(root) do
      workspace = %__MODULE__{
        path: path,
        key: key,
        root: root,
        strategy: strategy
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
  Runs the `before_run` hook in the workspace directory.
  """
  @spec before_run(t(), map()) :: :ok | {:error, String.t()}
  def before_run(%__MODULE__{} = workspace, hooks) do
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
    source = expand_root(config.workspace.source || ".")
    prefix = Map.get(config.workspace, :branch_prefix, "kollywood/")
    branch = "#{prefix}#{workspace.key}"

    Logger.info("Creating worktree for #{identifier} at #{workspace.path} (branch: #{branch})")

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
        # Branch may already exist — try adding worktree for existing branch
        case git(["worktree", "add", workspace.path, branch], source) do
          {_output, 0} ->
            {:ok, %{workspace | branch: branch}}

          {_, _} ->
            {:error, "Failed to create worktree: #{String.trim(output)}"}
        end
    end
  end

  # --- Private: removal ---

  defp do_remove(%__MODULE__{strategy: :worktree} = workspace) do
    # Find the source repo by reading the worktree's .git file
    git_file = Path.join(workspace.path, ".git")

    source =
      case File.read(git_file) do
        {:ok, content} ->
          # .git file contains "gitdir: /path/to/source/.git/worktrees/<name>"
          content
          |> String.trim()
          |> String.replace_prefix("gitdir: ", "")
          |> Path.dirname()
          |> Path.dirname()
          |> Path.dirname()

        _ ->
          workspace.root
      end

    case git(["worktree", "remove", "--force", workspace.path], source) do
      {_, 0} ->
        Logger.info("Removed worktree at #{workspace.path}")

        if workspace.branch do
          git(["branch", "-D", workspace.branch], source)
        end

        :ok

      {output, _} ->
        Logger.error("Failed to remove worktree: #{String.trim(output)}")
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
    case workspace.strategy do
      :worktree ->
        prefix = Map.get(config.workspace, :branch_prefix, "kollywood/")
        %{workspace | branch: "#{prefix}#{workspace.key}"}

      _ ->
        workspace
    end
  end

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

  defp git(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
