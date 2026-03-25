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
end
