ExUnit.start(exclude: [:docker_integration])

# Keep control-state backend deterministic in tests even when the shell exports
# KOLLYWOOD_CONTROL_STATE_BACKEND (for example from a local dev session).
System.delete_env("KOLLYWOOD_CONTROL_STATE_BACKEND")
Application.put_env(:kollywood, :orchestrator_control_state_backend, :file)

# Run migrations directly (Bootstrap is disabled in test to avoid pool conflicts).
migrations_path = Application.app_dir(:kollywood, "priv/repo/migrations")
db_path = Application.get_env(:kollywood, Kollywood.Repo)[:database]

if Kollywood.Repo.__adapter__() == Ecto.Adapters.SQLite3 and is_binary(db_path) and
     db_path != ":memory:" do
  File.mkdir_p!(Path.dirname(Path.expand(db_path)))
end

Ecto.Migrator.run(Kollywood.Repo, migrations_path, :up, all: true)

# Switch to :manual so each test must explicitly check out a sandbox connection.
Ecto.Adapters.SQL.Sandbox.mode(Kollywood.Repo, :manual)
