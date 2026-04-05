defmodule Kollywood.RecoveryGuidance do
  @moduledoc false

  @type guidance :: %{summary: String.t(), commands: [String.t()]}

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

  @spec normalize(term()) :: guidance() | nil
  def normalize(value) when is_binary(value), do: parse(value)

  def normalize(value) when is_map(value) do
    summary = normalize_summary(map_field(value, "summary"))
    commands = normalize_commands(map_field(value, "commands"))

    if non_empty_string?(summary) and commands != [] do
      %{summary: summary, commands: commands}
    else
      nil
    end
  end

  def normalize(_value), do: nil

  @spec parse(String.t() | nil) :: guidance() | nil
  def parse(value) when is_binary(value) do
    trimmed = String.trim(value)

    with true <- non_empty_string?(trimmed),
         %{"summary" => summary, "commands" => commands_block} <-
           Regex.named_captures(
             ~r/\A(?<summary>.+?)\nRecovery commands:\n(?<commands>.+)\z/s,
             trimmed
           ) do
      normalize(%{
        "summary" => summary,
        "commands" => String.split(commands_block, ~r/\r?\n/, trim: true)
      })
    else
      _other -> nil
    end
  end

  def parse(_value), do: nil

  @spec text(guidance()) :: String.t()
  def text(%{summary: summary, commands: commands}) do
    case normalize(%{summary: summary, commands: commands}) do
      %{summary: normalized_summary, commands: normalized_commands} ->
        [normalized_summary, "Recovery commands:"]
        |> Kernel.++(Enum.map(normalized_commands, &("  " <> &1)))
        |> Enum.join("\n")

      nil ->
        summary
    end
  end

  defp map_field(map, "summary"), do: Map.get(map, "summary") || Map.get(map, :summary)
  defp map_field(map, "commands"), do: Map.get(map, "commands") || Map.get(map, :commands)
  defp map_field(_map, _key), do: nil

  defp normalize_summary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_summary(nil), do: nil

  defp normalize_summary(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_summary()

  defp normalize_summary(_value), do: nil

  defp normalize_commands(value) when is_list(value) do
    value
    |> Enum.map(&normalize_summary/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_commands(_value), do: []

  defp sh(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp sh(value) when is_atom(value), do: value |> Atom.to_string() |> sh()
  defp sh(value), do: value |> to_string() |> sh()

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
