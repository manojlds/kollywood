defmodule Kollywood.Repo do
  @adapter Application.compile_env(:kollywood, :ecto_adapter, Ecto.Adapters.SQLite3)

  use Ecto.Repo,
    otp_app: :kollywood,
    adapter: @adapter
end
