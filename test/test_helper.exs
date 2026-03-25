ExUnit.start()

# Bootstrap runs migrations in :auto mode during app startup above.
# Switch to :manual so each test must explicitly check out a sandbox connection.
Ecto.Adapters.SQL.Sandbox.mode(Kollywood.Repo, :manual)
