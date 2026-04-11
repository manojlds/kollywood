defmodule KollywoodWeb.AdminLiveTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.Projects
  alias Kollywood.Repo
  alias Kollywood.RunAttempts
  alias Kollywood.RunAttempts.Attempt, as: Entry
  alias Kollywood.WorkerConsumer

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "kollywood_admin_live_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    {:ok, project} =
      Projects.create_project(%{
        name: "Admin Test Project #{System.unique_integer([:positive])}",
        provider: :local,
        repository: tmp_dir
      })

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    %{project: project}
  end

  test "renders workers list and worker detail", %{conn: conn, project: project} do
    worker_id = "Kollywood.WorkerConsumer.1"

    {:ok, worker_pid} =
      WorkerConsumer.start_link(
        name: String.to_atom(worker_id),
        agent_pool: nil,
        poll_interval_ms: 60_000,
        max_local_workers: 2
      )

    on_exit(fn ->
      if Process.alive?(worker_pid), do: GenServer.stop(worker_pid)
    end)

    entry =
      %Entry{}
      |> Entry.changeset(%{
        issue_id: "US-056-WRK",
        identifier: "US-056",
        project_slug: project.slug,
        status: "running",
        attempt: 2,
        config_snapshot:
          Jason.encode!(%{"issue" => %{"id" => "US-056-WRK", "title" => "Workers Detail Story"}}),
        run_opts_snapshot: Jason.encode!(%{}),
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    :sys.replace_state(worker_pid, fn state ->
      %{
        state
        | active_workers: %{
            entry.id => %{
              worker_pid: self(),
              monitor_ref: make_ref(),
              issue_id: entry.issue_id,
              issue_title: "Workers Detail Story",
              identifier: entry.identifier,
              project_slug: entry.project_slug,
              attempt: entry.attempt,
              started_at: DateTime.utc_now()
            }
          },
          poll_count: 12,
          claim_attempts: 20,
          claims_succeeded: 10,
          last_poll_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
      }
    end)

    {:ok, view, html} = live(conn, ~p"/admin/workers")

    assert html =~ "Workers"
    assert html =~ worker_id

    view |> element("#workers-list a", worker_id) |> render_click()
    assert_patch(view, ~p"/admin/workers/#{worker_id}")

    detail_html = render(view)
    assert detail_html =~ "Worker Detail: #{worker_id}"
    assert detail_html =~ "Claim success rate"
    assert detail_html =~ "Workers Detail Story"
    assert detail_html =~ "Run detail"
  end

  test "updates workers UI from run queue pubsub events", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/workers")
    refute html =~ "US-056-PUBSUB"

    {:ok, _entry} =
      RunAttempts.enqueue(%{
        issue_id: "US-056-PUBSUB",
        identifier: "US-056",
        run_opts_snapshot: Jason.encode!(%{})
      })

    assert render(view) =~ "US-056-PUBSUB"
  end

  test "navigates from worker detail to run detail", %{conn: conn, project: project} do
    worker_id = "Kollywood.WorkerConsumer.1"

    {:ok, worker_pid} =
      WorkerConsumer.start_link(
        name: String.to_atom(worker_id),
        agent_pool: nil,
        poll_interval_ms: 60_000,
        max_local_workers: 1
      )

    on_exit(fn ->
      if Process.alive?(worker_pid), do: GenServer.stop(worker_pid)
    end)

    entry =
      %Entry{}
      |> Entry.changeset(%{
        issue_id: "US-056-RUN",
        identifier: "US-056",
        project_slug: project.slug,
        status: "running",
        attempt: 3,
        config_snapshot:
          Jason.encode!(%{"issue" => %{"id" => "US-056-RUN", "title" => "Navigation Story"}}),
        run_opts_snapshot: Jason.encode!(%{}),
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    :sys.replace_state(worker_pid, fn state ->
      %{
        state
        | active_workers: %{
            entry.id => %{
              worker_pid: self(),
              monitor_ref: make_ref(),
              issue_id: entry.issue_id,
              issue_title: "Navigation Story",
              identifier: entry.identifier,
              project_slug: entry.project_slug,
              attempt: entry.attempt,
              started_at: DateTime.utc_now()
            }
          },
          last_poll_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
      }
    end)

    {:ok, view, _html} = live(conn, ~p"/admin/workers/#{worker_id}")

    view
    |> element("#worker-active-runs a", "Run detail")
    |> render_click()

    assert_redirect(view, ~p"/projects/#{project.slug}/runs/US-056-RUN/3")
  end
end
