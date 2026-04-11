defmodule Kollywood.Version do
  @moduledoc "Runtime-aware version info for the current build/release."

  @mix_version Mix.Project.config()[:version]
  @compile_time DateTime.utc_now() |> DateTime.to_iso8601()
  @cache_key {__MODULE__, :build_info}

  def version do
    System.get_env("RELEASE_VSN") || @mix_version
  end

  def git_sha do
    build_info().git_sha
  end

  def build_time do
    build_info().build_time
  end

  def full do
    "#{version()}+#{git_sha()}"
  end

  @doc false
  def reset_cache do
    :persistent_term.erase(@cache_key)
  end

  defp build_info do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        info = %{
          git_sha: resolve_git_sha(),
          build_time: resolve_build_time()
        }

        :persistent_term.put(@cache_key, info)
        info

      info ->
        info
    end
  end

  defp resolve_git_sha do
    case System.get_env("KOLLYWOOD_GIT_SHA") do
      value when is_binary(value) and value != "" ->
        String.trim(value)

      _other ->
        case System.cmd("git", ["rev-parse", "--short=8", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha)
          _ -> "unknown"
        end
    end
  end

  defp resolve_build_time do
    case System.get_env("KOLLYWOOD_BUILD_TIME") do
      value when is_binary(value) and value != "" ->
        String.trim(value)

      _other ->
        release_build_time() || @compile_time
    end
  end

  defp release_build_time do
    release_root = System.get_env("RELEASE_ROOT")
    release_vsn = System.get_env("RELEASE_VSN") || @mix_version

    if is_binary(release_root) and release_root != "" do
      release_root
      |> release_time_candidates(release_vsn)
      |> Enum.find_value(&file_mtime_iso8601/1)
    end
  end

  defp release_time_candidates(release_root, release_vsn) do
    [
      Path.join([release_root, "releases", release_vsn, "start.boot"]),
      Path.join([release_root, "releases", "start_erl.data"])
    ]
  end

  defp file_mtime_iso8601(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        mtime
        |> DateTime.from_unix!(:second)
        |> DateTime.to_iso8601()

      _other ->
        nil
    end
  end
end
