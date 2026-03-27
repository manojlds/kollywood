defmodule Kollywood.RepoSync do
  @moduledoc """
  Synchronizes a local repository to the best available branch reference.

  This prefers `origin/<branch>` when available, and falls back to
  `origin/HEAD`, local branches, then `HEAD` so local-only repos still sync.
  """

  @default_branch "main"

  @spec sync(String.t() | nil, String.t() | nil) :: :ok | {:error, String.t()}
  def sync(local_path, branch \\ @default_branch)

  def sync(nil, _branch), do: :ok

  def sync(local_path, branch) when is_binary(local_path) do
    branch = normalize_ref(branch)

    with :ok <- ensure_directory(local_path),
         :ok <- ensure_git_repo(local_path),
         :ok <- fetch_if_possible(local_path),
         {:ok, target_ref} <- resolve_target_ref(local_path, branch),
         {_, 0} <- git(["reset", "--hard", target_ref], local_path) do
      :ok
    else
      {:error, _reason} = error ->
        error

      {output, code} ->
        {:error, "git reset exited #{code}: #{String.trim(output)}"}
    end
  end

  def sync(_local_path, _branch), do: {:error, "local path must be a string"}

  defp ensure_directory(local_path) do
    if File.dir?(local_path) do
      :ok
    else
      {:error, "local path is not a directory: #{local_path}"}
    end
  end

  defp ensure_git_repo(local_path) do
    case git(["rev-parse", "--is-inside-work-tree"], local_path) do
      {output, 0} ->
        if String.trim(output) == "true" do
          :ok
        else
          {:error, "not a git repository: #{String.trim(output)}"}
        end

      {output, code} ->
        {:error, "not a git repository (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp fetch_if_possible(local_path) do
    case git(["fetch", "--all", "--prune"], local_path) do
      {_, 0} ->
        :ok

      {output, code} ->
        case has_remote?(local_path) do
          {:ok, false} ->
            :ok

          {:ok, true} ->
            {:error, "git fetch exited #{code}: #{String.trim(output)}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp has_remote?(local_path) do
    case git(["remote"], local_path) do
      {output, 0} ->
        remotes = String.split(output, "\n", trim: true)
        {:ok, remotes != []}

      {output, code} ->
        {:error, "failed to list git remotes (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp resolve_target_ref(local_path, branch) do
    refs =
      []
      |> add_requested_branch_refs(branch)
      |> add_ref(remote_head_ref(local_path))
      |> add_current_branch_refs(local_path)
      |> add_ref("HEAD")
      |> Enum.uniq()

    case Enum.find(refs, &ref_exists?(local_path, &1)) do
      nil ->
        {:error, "could not resolve a sync target ref#{branch_suffix(branch)}"}

      ref ->
        {:ok, ref}
    end
  end

  defp add_requested_branch_refs(refs, nil), do: refs

  defp add_requested_branch_refs(refs, branch) do
    refs
    |> add_ref("origin/#{branch}")
    |> add_ref(branch)
  end

  defp add_current_branch_refs(refs, local_path) do
    case current_branch_ref(local_path) do
      nil ->
        refs

      branch ->
        refs
        |> add_ref("origin/#{branch}")
        |> add_ref(branch)
    end
  end

  defp current_branch_ref(local_path) do
    case git(["symbolic-ref", "--quiet", "--short", "HEAD"], local_path) do
      {output, 0} -> normalize_ref(output)
      _ -> nil
    end
  end

  defp remote_head_ref(local_path) do
    case git(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], local_path) do
      {output, 0} -> normalize_ref(output)
      _ -> nil
    end
  end

  defp ref_exists?(local_path, ref) do
    case git(["rev-parse", "--verify", "--quiet", ref], local_path) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp normalize_ref(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      ref -> ref
    end
  end

  defp normalize_ref(_value), do: nil

  defp add_ref(refs, nil), do: refs
  defp add_ref(refs, ref), do: refs ++ [ref]

  defp branch_suffix(nil), do: ""
  defp branch_suffix(branch), do: " for branch #{branch}"

  defp git(args, cwd) do
    System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
