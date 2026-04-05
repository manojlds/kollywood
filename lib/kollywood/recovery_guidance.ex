defmodule Kollywood.RecoveryGuidance do
  @moduledoc false

  @spec workspace_branch_collision(String.t(), String.t(), String.t(), String.t() | nil) ::
          String.t()
  def workspace_branch_collision(source, branch, workspace_path, existing_path \\ nil) do
    summary =
      if non_empty_string?(existing_path) do
        "workspace branch collision: #{branch} is already attached at #{existing_path}"
      else
        "workspace branch collision: #{branch} already exists"
      end

    commands = [
      "git -C #{sh(source)} worktree list --porcelain",
      "git -C #{sh(source)} worktree prune",
      "git -C #{sh(source)} branch --list #{sh(branch)}",
      "rm -rf #{sh(workspace_path)}  # only if this path is stale",
      "git -C #{sh(source)} branch -D #{sh(branch)}  # only if branch is stale"
    ]

    format(summary, commands)
  end

  @spec workspace_path_collision(String.t(), String.t()) :: String.t()
  def workspace_path_collision(source, workspace_path) do
    format(
      "workspace path collision: #{workspace_path} already exists and is not a known worktree",
      [
        "ls -la #{sh(workspace_path)}",
        "git -C #{sh(source)} worktree list --porcelain",
        "git -C #{sh(source)} worktree prune",
        "rm -rf #{sh(workspace_path)}  # only if this directory is stale"
      ]
    )
  end

  @spec workspace_prune_failed(String.t(), non_neg_integer(), String.t()) :: String.t()
  def workspace_prune_failed(source, exit_code, output) do
    format(
      "workspace preflight failed: git worktree prune exited #{exit_code}: #{output}",
      [
        "git -C #{sh(source)} worktree list --porcelain",
        "git -C #{sh(source)} worktree prune"
      ]
    )
  end

  @spec workspace_list_failed(String.t(), non_neg_integer(), String.t()) :: String.t()
  def workspace_list_failed(source, exit_code, output) do
    format(
      "workspace preflight failed: git worktree list exited #{exit_code}: #{output}",
      [
        "git -C #{sh(source)} worktree list --porcelain",
        "git -C #{sh(source)} worktree prune"
      ]
    )
  end

  @spec workspace_create_failed(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def workspace_create_failed(source, branch, workspace_path, output) do
    format(
      "failed to create worktree for #{branch} at #{workspace_path}: #{output}",
      [
        "git -C #{sh(source)} worktree list --porcelain",
        "git -C #{sh(source)} worktree prune",
        "git -C #{sh(source)} branch --list #{sh(branch)}"
      ]
    )
  end

  @spec publish_push_failed(String.t(), String.t(), String.t()) :: String.t()
  def publish_push_failed(workspace_path, branch, reason) do
    format(
      "push failed for branch #{branch}: #{reason}",
      [
        "git -C #{sh(workspace_path)} status --short",
        "git -C #{sh(workspace_path)} remote -v",
        "git -C #{sh(workspace_path)} push -u origin #{sh(branch)}"
      ]
    )
  end

  @spec publish_merge_failed(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def publish_merge_failed(source, branch, base_branch, reason) do
    format(
      "merge failed for #{branch} into #{base_branch}: #{reason}",
      [
        "git -C #{sh(source)} status --short",
        "git -C #{sh(source)} checkout #{sh(base_branch)}",
        "git -C #{sh(source)} merge --no-ff #{sh(branch)}",
        "git -C #{sh(source)} push origin #{sh(base_branch)}"
      ]
    )
  end

  @spec repo_sync_failed(String.t() | nil, String.t() | nil, String.t()) :: String.t()
  def repo_sync_failed(local_path, branch, reason) do
    normalized_branch = if non_empty_string?(branch), do: branch, else: "main"

    commands =
      if non_empty_string?(local_path) do
        [
          "git -C #{sh(local_path)} fetch --all --prune",
          "git -C #{sh(local_path)} reset --hard origin/#{normalized_branch}"
        ]
      else
        [
          "git fetch --all --prune",
          "git reset --hard origin/#{normalized_branch}"
        ]
      end

    format("Repository sync failed: #{reason}", commands)
  end

  @spec repo_sync_timeout(
          String.t() | nil,
          String.t() | nil,
          non_neg_integer(),
          non_neg_integer()
        ) ::
          String.t()
  def repo_sync_timeout(local_path, branch, duration_ms, timeout_ms) do
    normalized_branch = if non_empty_string?(branch), do: branch, else: "main"

    commands =
      if non_empty_string?(local_path) do
        [
          "git -C #{sh(local_path)} fetch --all --prune",
          "git -C #{sh(local_path)} reset --hard origin/#{normalized_branch}"
        ]
      else
        [
          "git fetch --all --prune",
          "git reset --hard origin/#{normalized_branch}"
        ]
      end

    format(
      "Repository sync timed out after #{duration_ms}ms (timeout=#{timeout_ms}ms)",
      commands
    )
  end

  @spec format(String.t(), [String.t()]) :: String.t()
  def format(summary, commands) when is_binary(summary) and is_list(commands) do
    command_lines =
      commands
      |> Enum.filter(&non_empty_string?/1)
      |> Enum.map(&("  " <> &1))

    case command_lines do
      [] ->
        summary

      _ ->
        [summary, "Recovery commands:"]
        |> Kernel.++(command_lines)
        |> Enum.join("\n")
    end
  end

  defp sh(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp sh(value) when is_atom(value), do: value |> Atom.to_string() |> sh()
  defp sh(value), do: value |> to_string() |> sh()

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
