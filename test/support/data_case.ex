defmodule Kollywood.DataCase do
  @moduledoc """
  Test case for tests that interact with the database but don't need a web connection.
  Sets up the SQL sandbox so changes are rolled back after each test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Kollywood.Repo
      import Kollywood.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Kollywood.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
