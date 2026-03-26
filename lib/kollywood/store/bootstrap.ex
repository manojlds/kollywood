defmodule Kollywood.Store.Bootstrap do
  @moduledoc """
  Boots the SQLite-backed control store by running migrations.
  """

  use GenServer
  require Logger

  alias Kollywood.Repo

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Application.get_env(:kollywood, :store_bootstrap_enabled, true) do
      run_bootstrap!()
    end

    {:ok, %{}}
  end

  defp run_bootstrap! do
    db_path = Application.get_env(:kollywood, Repo)[:database]

    if is_binary(db_path) and db_path != ":memory:" do
      File.mkdir_p!(Path.dirname(Path.expand(db_path)))
    end

    migrations_path = Application.app_dir(:kollywood, "priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations_path, :up, all: true)
  rescue
    error ->
      Logger.error("Store bootstrap failed: #{Exception.message(error)}")
      reraise(error, __STACKTRACE__)
  end
end
