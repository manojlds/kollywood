defmodule Kollywood.ProjectRepoSyncTest do
  use ExUnit.Case, async: true

  alias Kollywood.ProjectRepoSync
  alias Kollywood.ServiceConfig

  test "syncs only enabled projects with valid slugs" do
    parent = self()

    projects = [
      %{slug: "one", enabled: true, default_branch: "main"},
      %{slug: "two", enabled: true, default_branch: nil},
      %{slug: "three", enabled: false, default_branch: "main"},
      %{slug: nil, enabled: true, default_branch: "main"}
    ]

    assert :ok =
             ProjectRepoSync.sync_projects(projects, fn local_path, branch ->
               send(parent, {:synced, local_path, branch})
               :ok
             end)

    assert_receive {:synced, path_one, "main"}
    assert_receive {:synced, path_two, "main"}
    assert path_one == ServiceConfig.project_repos_path("one")
    assert path_two == ServiceConfig.project_repos_path("two")
    refute_receive {:synced, _, _branch}
  end

  test "continues syncing even when one project fails" do
    parent = self()

    projects = [
      %{slug: "one", enabled: true, default_branch: "main"},
      %{slug: "two", enabled: true, default_branch: "main"}
    ]

    assert :ok =
             ProjectRepoSync.sync_projects(projects, fn local_path, branch ->
               send(parent, {:synced, local_path, branch})

               if local_path == ServiceConfig.project_repos_path("one") do
                 {:error, "forced failure"}
               else
                 :ok
               end
             end)

    assert_receive {:synced, path_one, "main"}
    assert_receive {:synced, path_two, "main"}
    assert path_one == ServiceConfig.project_repos_path("one")
    assert path_two == ServiceConfig.project_repos_path("two")
  end
end
