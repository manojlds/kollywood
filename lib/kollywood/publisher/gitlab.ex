defmodule Kollywood.Publisher.GitLab do
  @moduledoc """
  Publisher adapter for GitLab using the `glab` CLI.

  Requires `glab` to be installed and authenticated in the environment
  where Kollywood runs (`glab auth login` or `GITLAB_TOKEN` env var).
  """

  @behaviour Kollywood.Publisher

  require Logger

  @impl true
  def create_pr(workspace, %{draft: draft, base_branch: base, title: title, body: body}) do
    args =
      [
        "mr",
        "create",
        "--source-branch",
        workspace.branch,
        "--target-branch",
        base,
        "--title",
        title,
        "--description",
        body,
        "--yes"
      ]
      |> then(fn args -> if draft, do: args ++ ["--draft"], else: args end)

    Logger.info("Creating GitLab MR: branch=#{workspace.branch} base=#{base} draft=#{draft}")

    case System.cmd("glab", args, cd: workspace.path, stderr_to_stdout: true) do
      {output, 0} ->
        url = output |> String.trim() |> String.split("\n") |> List.last()
        Logger.info("GitLab MR created: #{url}")
        {:ok, url}

      {output, code} ->
        {:error, "glab mr create exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "glab mr create failed: #{Exception.message(e)}"}
  end

  @impl true
  def enable_auto_merge(workspace, pr_url) when is_binary(pr_url) do
    args = ["mr", "merge", "--auto-merge", "--yes", pr_url]

    Logger.info("Enabling GitLab MR auto-merge: #{pr_url}")

    case System.cmd("glab", args, cd: workspace.path, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "glab mr merge --auto-merge exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "glab mr merge --auto-merge failed: #{Exception.message(e)}"}
  end

  @impl true
  def merged?(workspace, pr_url) when is_binary(pr_url) do
    args = ["mr", "view", pr_url, "--output", "json"]

    case System.cmd("glab", args, cd: workspace.path, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, payload} ->
            state = payload |> Map.get("state", "") |> to_string() |> String.downcase()
            {:ok, state == "merged"}

          {:error, reason} ->
            {:error, "glab mr view returned invalid JSON: #{inspect(reason)}"}
        end

      {output, code} ->
        {:error, "glab mr view exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e -> {:error, "glab mr view failed: #{Exception.message(e)}"}
  end
end
