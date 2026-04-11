defmodule Kollywood.VersionTest do
  use ExUnit.Case, async: false

  alias Kollywood.Version

  setup do
    original_git_sha = System.get_env("KOLLYWOOD_GIT_SHA")
    original_build_time = System.get_env("KOLLYWOOD_BUILD_TIME")

    Version.reset_cache()

    on_exit(fn ->
      restore_env("KOLLYWOOD_GIT_SHA", original_git_sha)
      restore_env("KOLLYWOOD_BUILD_TIME", original_build_time)
      Version.reset_cache()
    end)

    :ok
  end

  test "prefers environment-provided build metadata" do
    System.put_env("KOLLYWOOD_GIT_SHA", "deadbeef")
    System.put_env("KOLLYWOOD_BUILD_TIME", "2026-04-11T17:00:00Z")
    Version.reset_cache()

    assert Version.git_sha() == "deadbeef"
    assert Version.build_time() == "2026-04-11T17:00:00Z"
    assert Version.full() =~ "+deadbeef"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
