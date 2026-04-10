defmodule Kollywood.Scheduler.LeaseTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Kollywood.Repo
  alias Kollywood.Scheduler.Lease

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "acquire grants leadership to one owner at a time" do
    assert {:ok, %{leader?: true, owner_id: "owner-a"}} =
             Lease.acquire("orch", "owner-a", 5_000)

    assert {:ok, %{leader?: false, owner_id: "owner-a"}} =
             Lease.acquire("orch", "owner-b", 5_000)
  end

  test "expired lease can be taken by another owner" do
    assert {:ok, %{leader?: true}} = Lease.acquire("orch", "owner-a", 5_000)

    stale_time = DateTime.add(DateTime.utc_now(), -60, :second)

    Repo.update_all(
      from(lease in Lease, where: lease.name == "orch"),
      set: [lease_expires_at: stale_time]
    )

    assert {:ok, %{leader?: true, owner_id: "owner-b"}} =
             Lease.acquire("orch", "owner-b", 5_000)
  end
end
