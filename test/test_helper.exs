ExUnit.start(exclude: [:docker_integration])

# Run migrations directly (Bootstrap is disabled in test to avoid pool conflicts).
migrations_path = Application.app_dir(:kollywood, "priv/repo/migrations")
db_path = Application.get_env(:kollywood, Kollywood.Repo)[:database]

if Kollywood.Repo.__adapter__() == Ecto.Adapters.SQLite3 and is_binary(db_path) and db_path != ":memory:" do
  File.mkdir_p!(Path.dirname(Path.expand(db_path)))
end

Ecto.Migrator.run(Kollywood.Repo, migrations_path, :up, all: true)

# Switch to :manual so each test must explicitly check out a sandbox connection.
Ecto.Adapters.SQL.Sandbox.mode(Kollywood.Repo, :manual)
