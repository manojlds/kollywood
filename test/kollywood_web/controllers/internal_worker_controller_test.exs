defmodule KollywoodWeb.InternalWorkerControllerTest do
  use KollywoodWeb.ConnCase, async: false

  alias Kollywood.RunQueue

  setup do
    previous_token = Application.get_env(:kollywood, :internal_api_token)
    Application.put_env(:kollywood, :internal_api_token, "test-internal-token")

    on_exit(fn ->
      Application.put_env(:kollywood, :internal_api_token, previous_token)
    end)

    :ok
  end

  test "rejects unauthenticated requests", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/internal/workers/lease-next", %{worker_id: "worker-1", limit: 1})

    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "leases and completes work for an authenticated worker", %{conn: conn} do
    {:ok, entry} = RunQueue.enqueue(%{issue_id: "internal-1", identifier: "US-INT-1"})
    entry_id = entry.id

    lease_conn =
      conn
      |> auth_conn()
      |> post("/api/internal/workers/lease-next", %{worker_id: "worker-1", limit: 1})

    entries = get_in(json_response(lease_conn, 200), ["data", "entries"])
    assert [%{"id" => ^entry_id, "issue_id" => "internal-1"}] = entries
    lease_token = hd(entries)["lease_token"]
    assert is_binary(lease_token)

    start_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/start", %{
        worker_id: "worker-1",
        lease_token: lease_token
      })

    assert get_in(json_response(start_conn, 200), ["data", "ok"]) == true

    heartbeat_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/heartbeat", %{
        worker_id: "worker-1",
        lease_token: lease_token
      })

    assert get_in(json_response(heartbeat_conn, 200), ["data", "ok"]) == true

    complete_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/complete", %{
        worker_id: "worker-1",
        lease_token: lease_token,
        result_payload: %{"status" => "ok"}
      })

    assert get_in(json_response(complete_conn, 200), ["data", "ok"]) == true

    refreshed = RunQueue.get(entry.id)
    assert refreshed.status == "completed"
    assert refreshed.claimed_by_node == "worker-1"
  end

  test "heartbeat reports cancellation requests and cancel-ack finalizes them", %{conn: conn} do
    {:ok, entry} = RunQueue.enqueue(%{issue_id: "internal-cancel", identifier: "US-INT-CANCEL"})

    lease_conn =
      conn
      |> auth_conn()
      |> post("/api/internal/workers/lease-next", %{worker_id: "worker-1", limit: 1})

    [%{"lease_token" => lease_token}] =
      get_in(json_response(lease_conn, 200), ["data", "entries"])

    start_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/start", %{
        worker_id: "worker-1",
        lease_token: lease_token
      })

    assert get_in(json_response(start_conn, 200), ["data", "ok"]) == true

    assert {:ok, _requested} = RunQueue.cancel(entry.id, "operator stop")

    heartbeat_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/heartbeat", %{
        worker_id: "worker-1",
        lease_token: lease_token
      })

    assert get_in(json_response(heartbeat_conn, 200), ["data", "cancel_requested"]) == true

    cancel_ack_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/cancel-ack", %{
        worker_id: "worker-1",
        lease_token: lease_token
      })

    assert get_in(json_response(cancel_ack_conn, 200), ["data", "ok"]) == true
    assert RunQueue.get(entry.id).status == "cancelled"
  end

  test "rejects requests with the wrong lease token", %{conn: conn} do
    {:ok, entry} = RunQueue.enqueue(%{issue_id: "internal-2", identifier: "US-INT-2"})

    lease_conn =
      conn
      |> auth_conn()
      |> post("/api/internal/workers/lease-next", %{worker_id: "worker-1", limit: 1})

    [%{"id" => entry_id}] = get_in(json_response(lease_conn, 200), ["data", "entries"])
    assert entry_id == entry.id

    conflict_conn =
      build_conn()
      |> auth_conn()
      |> post("/api/internal/runs/#{entry.id}/start", %{
        worker_id: "worker-1",
        lease_token: Ecto.UUID.generate()
      })

    assert json_response(conflict_conn, 409)["error"] == "run is not leased by this worker"
  end

  defp auth_conn(conn) do
    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer test-internal-token")
  end
end
