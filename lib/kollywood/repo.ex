defmodule Kollywood.Repo do
  use Ecto.Repo,
    otp_app: :kollywood,
    adapter: Ecto.Adapters.SQLite3
end
