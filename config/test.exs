import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kollywood, KollywoodWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "H1hYP+YNMLJ/ZL6RIfajl1S7yNpNrgQ8tuZ7Deb8tG7qxdVpAAA+bP4EINaCCVBB",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :kollywood, orchestrator_enabled: false
config :kollywood, orchestrator_retry_store: nil
config :kollywood, store_bootstrap_enabled: false

config :kollywood, Kollywood.Repo,
  database: Path.join(System.tmp_dir!(), "kollywood_test.db"),
  pool: Ecto.Adapters.SQL.Sandbox
