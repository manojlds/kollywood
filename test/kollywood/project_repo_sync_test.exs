defmodule Kollywood.ProjectRepoSyncTest do
  use ExUnit.Case, async: true

  alias Kollywood.ProjectRepoSync

  test "syncs only enabled projects with valid local paths" do
    parent = self()

    projects = [
      %{slug: "one", enabled: true, local_path: "/tmp/repo_one", default_branch: "main"},
      %{slug: "two", enabled: true, local_path: "/tmp/repo_two", default_branch: nil},
      %{slug: "three", enabled: false, local_path: "/tmp/repo_three", default_branch: "main"},
      %{slug: "four", enabled: true, local_path: nil, default_branch: "main"}
    ]

    assert :ok =
             ProjectRepoSync.sync_projects(projects, fn local_path, branch ->
               send(parent, {:synced, local_path, branch})
               :ok
             end)

    assert_receive {:synced, "/tmp/repo_one", "main"}
    assert_receive {:synced, "/tmp/repo_two", "main"}
    refute_receive {:synced, "/tmp/repo_three", _branch}
  end

  test "continues syncing even when one project fails" do
    parent = self()

    projects = [
      %{slug: "one", enabled: true, local_path: "/tmp/repo_one", default_branch: "main"},
      %{slug: "two", enabled: true, local_path: "/tmp/repo_two", default_branch: "main"}
    ]

    assert :ok =
             ProjectRepoSync.sync_projects(projects, fn local_path, branch ->
               send(parent, {:synced, local_path, branch})

               if local_path == "/tmp/repo_one" do
                 {:error, "forced failure"}
               else
                 :ok
               end
             end)

    assert_receive {:synced, "/tmp/repo_one", "main"}
    assert_receive {:synced, "/tmp/repo_two", "main"}
  end
end
