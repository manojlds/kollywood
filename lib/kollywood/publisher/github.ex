defmodule Kollywood.Publisher.GitHub do
  @moduledoc """
  Publisher adapter for GitHub using the `gh` CLI.

  Requires `gh` to be installed and authenticated in the environment
  where Kollywood runs (`gh auth login` or `GH_TOKEN` env var).
  """

  @behaviour Kollywood.Publisher

  require Logger

  @impl true
  def create_pr(workspace, %{draft: draft, base_branch: base, title: title, body: body}) do
    args =
      [
        "pr",
        "create",
        "--head",
        workspace.branch,
        "--base",
        base,
        "--title",
        title,
        "--body",
        body
      ]
      |> then(fn args -> if draft, do: args ++ ["--draft"], else: args end)

    Logger.info("Creating GitHub PR: branch=#{workspace.branch} base=#{base} draft=#{draft}")

    case System.cmd("gh", args, cd: workspace.path, stderr_to_stdout: true) do
      {output, 0} ->
        url = output |> String.trim() |> String.split("\n") |> List.last()
        Logger.info("GitHub PR created: #{url}")
        {:ok, url}

      {output, code} ->
        {:error, "gh pr create exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "gh pr create failed: #{Exception.message(e)}"}
  end

  @impl true
  def enable_auto_merge(workspace, pr_url) when is_binary(pr_url) do
    args = ["pr", "merge", "--auto", "--squash", pr_url]

    Logger.info("Enabling GitHub PR auto-merge: #{pr_url}")

    case System.cmd("gh", args, cd: workspace.path, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "gh pr merge --auto exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "gh pr merge --auto failed: #{Exception.message(e)}"}
  end
end
