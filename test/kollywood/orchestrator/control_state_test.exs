defmodule Kollywood.Orchestrator.ControlStateTest do
  use ExUnit.Case, async: false

  alias Kollywood.Orchestrator.ControlState
  alias Kollywood.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    previous_backend = Application.get_env(:kollywood, :orchestrator_control_state_backend)
    Application.put_env(:kollywood, :orchestrator_control_state_backend, :db)

    on_exit(fn ->
      Application.put_env(:kollywood, :orchestrator_control_state_backend, previous_backend)
    end)

    :ok
  end

  test "writes and reads maintenance mode through the shared store" do
    assert :ok = ControlState.write_maintenance_mode(:drain, source: "test")
    assert {:ok, :drain} = ControlState.read_maintenance_mode()

    assert :ok = ControlState.write_maintenance_mode(:normal, source: "test")
    assert {:ok, :normal} = ControlState.read_maintenance_mode()
  end

  test "writes and reads status through the shared store" do
    assert :ok = ControlState.write_status(%{maintenance_mode: "drain", running_count: 0})

    assert {:ok, %{"maintenance_mode" => "drain", "running_count" => 0}} =
             ControlState.read_status()
  end
end
