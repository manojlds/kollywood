defmodule Kollywood.Workspace do
  @moduledoc """
  Manages per-issue isolated workspace directories.

  Each issue gets a directory at `<workspace_root>/<sanitized_identifier>`.
  Workspaces persist across retries and continuation runs.

  ## Lifecycle hooks

  Four shell hooks can be configured in WORKFLOW.md:

  - `after_create` — runs once when a new workspace is created (fatal on failure)
  - `before_run` — runs before each agent turn (fatal on failure)
  - `after_run` — runs after each attempt (failure ignored)
  - `before_remove` — runs before workspace deletion (failure ignored)
  """

  require Logger

  @type t :: %__MODULE__{
          path: String.t(),
          key: String.t(),
          root: String.t()
        }

  defstruct [:path, :key, :root]

  @doc """
  Creates or reuses a workspace for the given issue identifier.

  Returns `{:ok, workspace}` if the workspace exists or was created successfully.
  Returns `{:error, reason}` if creation or the `after_create` hook fails.
  """
  @spec create_for_issue(String.t(), map()) :: {:ok, t()} | {:error, String.t()}
  def create_for_issue(identifier, config) do
    root = expand_root(config.workspace.root)
    key = sanitize_key(identifier)
    path = Path.join(root, key)

    with :ok <- validate_path(path, root) do
      workspace = %__MODULE__{path: path, key: key, root: root}

      if File.dir?(path) do
        Logger.info("Reusing workspace for #{identifier} at #{path}")
        {:ok, workspace}
      else
        create_new(workspace, identifier, config.hooks)
      end
    end
  end

  @doc """
  Runs the `before_run` hook in the workspace directory.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec before_run(t(), map()) :: :ok | {:error, String.t()}
  def before_run(%__MODULE__{} = workspace, hooks) do
    run_hook(hooks.before_run, workspace.path, "before_run")
  end

  @doc """
  Runs the `after_run` hook in the workspace directory.
  Always returns `:ok` (failures are logged but ignored).
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
  Removes the workspace directory after running the `before_remove` hook.
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

    case File.rm_rf(workspace.path) do
      {:ok, _} ->
        Logger.info("Removed workspace at #{workspace.path}")
        :ok

      {:error, reason, path} ->
        Logger.error("Failed to remove workspace at #{path}: #{reason}")
        :ok
    end
  end

  @doc """
  Sanitizes an issue identifier to a safe directory name.
  Only allows `[A-Za-z0-9._-]`, replaces everything else with `_`.
  """
  @spec sanitize_key(String.t()) :: String.t()
  def sanitize_key(identifier) do
    String.replace(identifier, ~r/[^A-Za-z0-9._-]/, "_")
  end

  # --- Private ---

  defp create_new(workspace, identifier, hooks) do
    Logger.info("Creating workspace for #{identifier} at #{workspace.path}")

    with :ok <- File.mkdir_p(workspace.path),
         :ok <- run_hook(hooks.after_create, workspace.path, "after_create") do
      {:ok, workspace}
    else
      {:error, reason} ->
        # Clean up on failure
        File.rm_rf(workspace.path)
        {:error, "Failed to create workspace: #{reason}"}
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
    e ->
      {:error, "#{name} hook failed: #{Exception.message(e)}"}
  end
end
