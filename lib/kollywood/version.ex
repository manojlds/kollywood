defmodule Kollywood.Version do
  @moduledoc "Compile-time version info from mix.exs and git."

  @mix_version Mix.Project.config()[:version]
  @git_sha (case System.cmd("git", ["rev-parse", "--short=8", "HEAD"],
                   stderr_to_stdout: true
                 ) do
              {sha, 0} -> String.trim(sha)
              _ -> "unknown"
            end)
  @build_time DateTime.utc_now() |> DateTime.to_iso8601()

  def version, do: @mix_version
  def git_sha, do: @git_sha
  def build_time, do: @build_time

  def full do
    "#{@mix_version}+#{@git_sha}"
  end
end
